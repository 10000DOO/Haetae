import Foundation
import HaetaeShared

/// 검사 ⑤ 보안 설정(WO-15, 3-5 ⑤, Q84·Q85). SIP·Gatekeeper·FileVault·방화벽·XProtect·보안 데이터 업데이트·부팅 보안·boot-args·
/// 라이브러리 검증·서드파티 kext를 본다. 수집(`collect`)과 판정(`evaluate` — 수집 결과만 받는 순수 함수, WO-19가 픽스처로 시험)을 나눈다.
/// 읽지 못한 항목은 `partial`로 올린다 — 안 보인 것을 해결로 보내지 않게.
public struct SecuritySettingsCheck: SecurityCheck {
    public let id = "system.security-settings"
    /// 명령 9개와 plist 해석 2번을 차례로 돈다(D26 동시 1개) — 명령마다 3초라 몇 개가 늦어도 다 잃지 않게 넉넉히(전체 상한 안).
    public let timeout: Duration = .seconds(20)
    public let needsBaseline = true
    public let baselineVersion = 1

    public init() {}

    public func run(_ ctx: CheckContext) async throws -> CheckResult {
        // 깨진 기준값은 던진다 — `CheckRunner`가 실패로 드러내고 이어지면 옆으로 옮긴 뒤 다시 학습한다(T13).
        let baseline: Baseline? = try ctx.baseline.map { try JSONWire.decode($0, maxBytes: Self.maxBaselineBytes) }
        var snapshot = await Self.collectCommands(ctx)
        try await Self.collectPlists(ctx, into: &snapshot)
        let rules = Rules(patterns: ctx.patterns)
        let (findings, next) = Self.evaluate(snapshot, baseline: baseline, rules: rules, checkID: id, now: Date())
        // 못 읽은 설정은 옛 값을 그대로 두고 합친 기준값이라 `partial`이어도 저장해도 된다 — 안 그러면 한 항목을 계속 못 읽는 동안
        // 다른 설정의 기준값이 묶여 "켜짐→꺼짐"(높음)이 "처음부터 꺼짐"(낮음)으로 약해진다(WO-15 보안 리뷰 Medium).
        return CheckResult(findings: findings, newBaseline: try JSONWire.encode(next), partial: !snapshot.unknown.isEmpty, baselineKeepsUnseen: true)
    }

    static let maxBaselineBytes = 64 * 1024
    static let commandTimeout: Duration = .seconds(3)
    static let maxOutputBytes = 256 * 1024
    static let maxPlistBytes = 1_000_000
    static let softwareUpdatePlist = "/Library/Preferences/com.apple.SoftwareUpdate.plist"
    static let libraryValidationPlist = "/Library/Preferences/com.apple.security.libraryvalidation.plist"
}

// MARK: - 값

extension SecuritySettingsCheck {
    /// 켜짐·꺼짐으로 보는 설정. rawValue가 기준값 키·지문 subject다 — 바꾸지 않는다(D18).
    enum Setting: String, CaseIterable, Codable, Sendable {
        case sip, gatekeeper, fileVault, firewall
        case xprotectLaunchScans, xprotectBackgroundScans
        case configDataInstall, criticalUpdateInstall, automaticCheck, automaticDownload
        case authenticatedRoot

        /// 꺼짐을 어떻게 볼지(3-5 ⑤, Q85).
        enum Policy {
            /// 꺼져 있으면 늘 높음 — 기본이 켜짐이라 꺼져 있으면 누가 끈 것이다.
            case highWhenOff
            /// 켜짐 → 꺼짐이면 높음(3-5 ⑤), 처음부터 꺼져 있으면 낮음(방화벽은 기본이 꺼짐, FileVault는 도난 대비 설정, 업데이트
            /// 자동 확인·다운로드는 편의 설정).
            case highOnTransition
        }

        var policy: Policy {
            switch self {
            case .sip, .gatekeeper, .xprotectLaunchScans, .xprotectBackgroundScans, .configDataInstall, .criticalUpdateInstall, .authenticatedRoot:
                .highWhenOff
            case .fileVault, .firewall, .automaticCheck, .automaticDownload:
                .highOnTransition
            }
        }

        /// 꺼져 있을 때의 제목(고정 문구).
        var offTitle: String {
            switch self {
            case .sip: "SIP(시스템 무결성 보호)가 꺼져 있음"
            case .gatekeeper: "Gatekeeper가 꺼져 있음"
            case .fileVault: "FileVault가 꺼져 있음"
            case .firewall: "방화벽이 꺼져 있음"
            case .xprotectLaunchScans: "XProtect 실행 검사가 꺼져 있음"
            case .xprotectBackgroundScans: "XProtect 백그라운드 검사가 꺼져 있음"
            case .configDataInstall: "보안 데이터(XProtect) 자동 설치가 꺼져 있음"
            case .criticalUpdateInstall: "보안 업데이트 자동 설치가 꺼져 있음"
            case .automaticCheck: "소프트웨어 업데이트 자동 확인이 꺼져 있음"
            case .automaticDownload: "업데이트 자동 다운로드가 꺼져 있음"
            case .authenticatedRoot: "서명된 시스템 볼륨 확인이 꺼져 있음"
            }
        }
    }

    /// 이번에 본 것. nil이면 읽지 못했다(`unknown`에 이유가 있다).
    struct Snapshot: Equatable, Sendable {
        var toggles: [Setting: Bool] = [:]
        /// 각 설정을 판정한 원문 한 줄(증거).
        var sources: [Setting: String] = [:]
        var xprotectVersion: String?
        var xprotectInstalled: Date?
        var secureBootLevel: String?
        /// 없으면 빈 문자열.
        var bootArgs: String?
        var libraryValidationDisabled: Bool?
        /// 번들 ID → 버전. `com.apple.`은 뺀다.
        var thirdPartyKexts: [String: String]?
        var unknown: Set<String> = []
    }

    /// 기준값(D7): 설정 → 켜짐 여부. 중간 이상을 낸 설정은 갱신하지 않는다(Q51) — 꺼짐이 기준이 되면 다음 실행부터 해결로 간다.
    struct Baseline: Codable, Equatable, Sendable {
        var toggles: [String: Bool] = [:]
    }

    /// 패턴 팩의 이 검사 구역(D23). 기본값은 여기 한 곳에만 둔다 — 팩은 조각을 더하기만 하고(빈 목록·틀린 값으로 검사가 꺼지지
    /// 않게), 날짜 기준은 1~90일 안에서만 바꾼다(설계·보안 리뷰 L).
    struct Rules: Equatable, Sendable {
        /// 서명 검사를 끄는 boot-args 조각(대소문자 무시, 부분 일치).
        var suspiciousBootArgs: [String]
        var xprotectMaxAgeDays: Double

        static let defaultSuspiciousBootArgs = ["amfi", "cs_enforcement_disable", "cs_debug", "cs_allow_invalid"]
        static let defaultXProtectMaxAgeDays = 30.0

        init(suspiciousBootArgs: [String] = Self.defaultSuspiciousBootArgs, xprotectMaxAgeDays: Double = Self.defaultXProtectMaxAgeDays) {
            self.suspiciousBootArgs = suspiciousBootArgs
            self.xprotectMaxAgeDays = xprotectMaxAgeDays
        }

        init(patterns: JSONValue) {
            let added = (patterns["suspiciousBootArgs"]?.strings ?? []).filter { !$0.isEmpty && !Self.defaultSuspiciousBootArgs.contains($0) }
            self.init(
                suspiciousBootArgs: Self.defaultSuspiciousBootArgs + added,
                xprotectMaxAgeDays: patterns["xprotectMaxAgeDays"]?.number.map { min(max($0, 1), 90) } ?? Self.defaultXProtectMaxAgeDays
            )
        }
    }
}

// MARK: - 판정

extension SecuritySettingsCheck {
    /// 수집 결과와 기준값으로 Finding과 새 기준값을 만든다(순수 함수).
    static func evaluate(
        _ snapshot: Snapshot, baseline: Baseline?, rules: Rules, checkID: String, now: Date
    ) -> (findings: [Finding], baseline: Baseline) {
        var findings: [Finding] = []
        var next = baseline ?? Baseline()

        func add(_ subject: String, _ contentHash: String, _ level: RiskLevel, _ title: String, _ evidence: String) {
            findings.append(Finding(
                checkID: checkID, title: title, evidence: evidence, ruleLevel: level,
                fingerprint: Fingerprint.make(checkID: checkID, subject: subject, contentHash: contentHash), observedAt: now
            ))
        }

        for setting in Setting.allCases {
            guard let on = snapshot.toggles[setting] else { continue }   // 못 읽은 것은 기준값도 그대로
            let was = baseline?.toggles[setting.rawValue]
            let source = snapshot.sources[setting].map { "\n원문: \($0)" } ?? ""
            var level: RiskLevel?
            if !on {
                switch setting.policy {
                case .highWhenOff:
                    level = .high
                case .highOnTransition:
                    level = was == true ? .high : .low
                }
                let evidence = (was == true ? "이전 검사에서는 켜져 있었는데 지금은 꺼져 있습니다." : "지금 꺼져 있습니다.") + source
                // SIP의 일부 해제(Custom Configuration)와 완전 해제는 다른 지문 — 더 약해지면 다시 알린다(설계 리뷰 의견).
                let state = setting == .sip && snapshot.sources[.sip]?.contains("Custom Configuration") == true ? "custom" : "off"
                add(setting.rawValue, state, level ?? .low, setting.offTitle, evidence)
            }
            // 중간 이상을 낸 설정은 기준값을 바꾸지 않는다(Q51).
            if level.map({ $0.rank < RiskLevel.medium.rank }) ?? true {
                next.toggles[setting.rawValue] = on
            }
        }

        if let level = snapshot.secureBootLevel, level.lowercased() != "full" {
            add("secureBootLevel", level, .high, "부팅 보안이 '전체 보안'이 아님",
                "부팅 보안 수준이 \(level)입니다. 전체 보안이 아니면 서드파티 커널 확장을 쓰거나 SIP를 끌 수 있습니다.")
        }

        if let bootArgs = snapshot.bootArgs {
            let lowered = bootArgs.lowercased()
            let hits = rules.suspiciousBootArgs.filter { lowered.contains($0.lowercased()) }
            if !hits.isEmpty {
                add("bootArgs", bootArgs, .high, "부팅 인자에 서명 검사를 끄는 설정이 있음",
                    "nvram boot-args: \(bootArgs)\n걸린 조각: \(hits.joined(separator: ", "))")
            }
        }

        if snapshot.libraryValidationDisabled == true {
            add("libraryValidation", "disabled", .high, "라이브러리 검증이 꺼져 있음",
                "\(libraryValidationPlist)의 DisableLibraryValidation이 켜져 있어 다른 서명의 dylib를 불러올 수 있습니다.")
        }

        for (bundleID, version) in (snapshot.thirdPartyKexts ?? [:]).sorted(by: { $0.key < $1.key }) {
            add("kext:\(bundleID)", version, .high, "서드파티 커널 확장이 로드됨: \(bundleID)",
                "kmutil showloaded: \(bundleID) (\(version)). Apple Silicon에서는 부팅 보안을 낮춰야만 로드됩니다.")
        }

        if let installed = snapshot.xprotectInstalled {
            let days = now.timeIntervalSince(installed) / 86_400
            if days > rules.xprotectMaxAgeDays {
                let version = snapshot.xprotectVersion ?? "?"
                add("xprotectAge", version, .medium, "XProtect 데이터가 오래 업데이트되지 않음",
                    "XProtect \(version)을 설치한 지 \(Int(days))일 지났습니다(기준 \(Int(rules.xprotectMaxAgeDays))일).")
            }
        }

        return (findings, next)
    }
}

// MARK: - 수집

extension SecuritySettingsCheck {
    /// 명령으로 읽는 것. 못 읽은 것은 `unknown`에.
    static func collectCommands(_ ctx: CheckContext) async -> Snapshot {
        var snapshot = Snapshot()

        func record(_ setting: Setting, _ parsed: (on: Bool, line: String)?, from command: String) {
            guard let parsed else { snapshot.unknown.insert(command); return }
            snapshot.toggles[setting] = parsed.on
            snapshot.sources[setting] = parsed.line
        }

        record(.sip, await text(ctx, "/usr/bin/csrutil", ["status"]).flatMap(parseSIP), from: "csrutil")
        record(.gatekeeper, await text(ctx, "/usr/sbin/spctl", ["--status"]).flatMap(parseGatekeeper), from: "spctl")
        record(.fileVault, await text(ctx, "/usr/bin/fdesetup", ["status"]).flatMap(parseFileVault), from: "fdesetup")
        record(.firewall, await text(ctx, "/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]).flatMap(parseFirewall), from: "socketfilterfw")

        let xprotect = await text(ctx, "/usr/bin/xprotect", ["status"]).map(parseXProtectStatus)
        record(.xprotectLaunchScans, xprotect?.launch, from: "xprotect status")
        record(.xprotectBackgroundScans, xprotect?.background, from: "xprotect status")
        if let version = await text(ctx, "/usr/bin/xprotect", ["version"]).flatMap(parseXProtectVersion) {
            snapshot.xprotectVersion = version.version
            snapshot.xprotectInstalled = version.installed
            // 설치일을 못 읽으면 오래됨 판정이 조용히 빠진다 — 확인 못 함으로 드러낸다(보안 리뷰 의견).
            if version.installed == nil { snapshot.unknown.insert("xprotect version date") }
        } else {
            snapshot.unknown.insert("xprotect version")
        }

        if let info = await text(ctx, "/usr/libexec/mdmclient", ["QuerySecurityInfo"]).map(parseSecurityInfo), info.secureBootLevel != nil || info.authenticatedRoot != nil {
            // 키 하나가 없는 것은 그 맥에 해당하지 않는 것이다(Intel 비T2 맥의 SecureBootLevel 등) — 확인 못 함으로 세지 않는다.
            snapshot.secureBootLevel = info.secureBootLevel
            if let root = info.authenticatedRoot {
                snapshot.toggles[.authenticatedRoot] = root
                snapshot.sources[.authenticatedRoot] = "AuthenticatedRootVolumeEnabled = \(root ? 1 : 0);"
            }
        } else {
            // root가 아니면 "[ERROR] Must be running as root"(종료 0)다 — 데몬은 root라 실제로는 읽힌다(Q84).
            snapshot.unknown.insert("mdmclient")
        }

        snapshot.bootArgs = await bootArgs(ctx)
        if snapshot.bootArgs == nil { snapshot.unknown.insert("nvram") }

        // 목록 명령은 종료 0을 요구한다 — 빈 목록도 정상 결과라, 실패한 출력을 "kext 없음"으로 읽으면 안 된다(설계 재리뷰 L1).
        let all = await listText(ctx, "/usr/bin/kmutil", ["showloaded", "--list-only"]).map(parseLoadedKexts)
        let boot = await listText(ctx, "/usr/bin/kmutil", ["showloaded", "--collection", "boot", "--list-only"]).map(parseLoadedKexts)
        let aux = await listText(ctx, "/usr/bin/kmutil", ["showloaded", "--collection", "aux", "--list-only"]).map(parseLoadedKexts)
        if let all, let boot, let aux, let kexts = thirdPartyKexts(all: all, boot: boot, aux: aux) {
            snapshot.thirdPartyKexts = kexts
        } else {
            snapshot.unknown.insert("kmutil")
        }

        return snapshot
    }

    /// root 소유 시스템 plist 2개. 해석 서비스를 쓸 수 없으면 던진다 — 파일 탓이 아니라 검사 실패 1건이다(8장, 보안 리뷰 L).
    static func collectPlists(_ ctx: CheckContext, into snapshot: inout Snapshot) async throws {
        switch try await plist(ctx, softwareUpdatePlist) {
        case .missing:
            // 파일이 없으면 모두 기본값(켜짐).
            for setting in [Setting.automaticCheck, .automaticDownload, .configDataInstall, .criticalUpdateInstall] {
                snapshot.toggles[setting] = true
                snapshot.sources[setting] = "\(softwareUpdatePlist) 없음 — 기본값(켜짐)"
            }
        case .value(let value):
            for (setting, key) in [(Setting.automaticCheck, "AutomaticCheckEnabled"), (.automaticDownload, "AutomaticDownload"),
                                   (.configDataInstall, "ConfigDataInstall"), (.criticalUpdateInstall, "CriticalUpdateInstall")] {
                if let parsed = softwareUpdateValue(value, key: key) {
                    snapshot.toggles[setting] = parsed.on
                    snapshot.sources[setting] = parsed.line
                } else {
                    snapshot.unknown.insert("SoftwareUpdate.plist \(key)")
                }
            }
        case .unreadable:
            snapshot.unknown.insert("SoftwareUpdate.plist")
        }

        switch try await plist(ctx, libraryValidationPlist) {
        case .missing:
            snapshot.libraryValidationDisabled = false
        case .value(let value):
            snapshot.libraryValidationDisabled = bool(value["DisableLibraryValidation"]) ?? false
        case .unreadable:
            snapshot.unknown.insert("libraryvalidation.plist")
        }
    }

    /// 목록을 내는 명령의 stdout. 종료 0일 때만 — 빈 결과가 정상일 수 있어 실패를 빈 목록으로 읽지 않게.
    private static func listText(_ ctx: CheckContext, _ executable: String, _ args: [String]) async -> String? {
        guard let output = try? await ctx.runner.run(executable, args, timeout: commandTimeout, maxBytes: maxOutputBytes),
              output.succeeded, !output.truncated else { return nil }
        return String(decoding: output.stdout, as: UTF8.self)
    }

    /// 명령의 stdout과 stderr. 종료 코드는 보지 않는다 — 상태를 묻는 명령이 "꺼짐"을 0이 아닌 코드로 알려도 그 줄을 읽어야 한다
    /// (꺼짐이 "확인 못 함"으로 바뀌지 않게, 설계 리뷰 M1). 알아볼 줄이 없으면 해석 함수가 nil을 낸다. 시간 초과·시그널·잘림은 nil.
    private static func text(_ ctx: CheckContext, _ executable: String, _ args: [String]) async -> String? {
        guard let output = try? await ctx.runner.run(executable, args, timeout: commandTimeout, maxBytes: maxOutputBytes),
              !output.timedOut, !output.terminatedBySignal, !output.truncated else { return nil }
        return String(decoding: output.stdout, as: UTF8.self) + "\n" + String(decoding: output.stderr, as: UTF8.self)
    }

    /// `nvram boot-args`. 변수가 없으면 종료 1과 "data was not found" — 오류가 아니라 빈 값이다(WO-15 실측).
    private static func bootArgs(_ ctx: CheckContext) async -> String? {
        guard let output = try? await ctx.runner.run("/usr/sbin/nvram", ["boot-args"], timeout: commandTimeout, maxBytes: maxOutputBytes),
              !output.timedOut, !output.terminatedBySignal, !output.truncated else { return nil }
        if output.exitCode == 0 { return parseBootArgs(String(decoding: output.stdout, as: UTF8.self)) }
        return String(decoding: output.stderr, as: UTF8.self).contains("data was not found") ? "" : nil
    }

    private enum PlistRead {
        case missing
        case value(ParsedValue)
        case unreadable
    }

    /// root 소유 시스템 plist. 해석은 해석 서비스에 맡긴다(Q42와 같게 — 데몬 안에서 plist를 풀지 않는다).
    private static func plist(_ ctx: CheckContext, _ path: String) async throws -> PlistRead {
        do {
            let data = try await ctx.reader.read(path: path, asUser: .root, maxBytes: maxPlistBytes)
            return .value(try await ctx.parser.parse(data, as: .plist))
        } catch SafeFileError.system(ENOENT) {
            return .missing
        } catch IsolatedParserError.unavailable {
            throw IsolatedParserError.unavailable
        } catch {
            return .unreadable
        }
    }
}

// MARK: - 출력 해석(순수 함수 — 픽스처로 시험)

extension SecuritySettingsCheck {
    /// "System Integrity Protection status: enabled." — "disabled."·"unknown (Custom Configuration)."은 꺼짐으로 본다(일부만 켜진 것도 약해진 것).
    static func parseSIP(_ text: String) -> (on: Bool, line: String)? {
        guard let line = firstLine(text, containing: "System Integrity Protection status:") else { return nil }
        return (line.hasSuffix("status: enabled."), line)
    }

    /// "assessments enabled" / "assessments disabled".
    static func parseGatekeeper(_ text: String) -> (on: Bool, line: String)? {
        guard let line = firstLine(text, containing: "assessments") else { return nil }
        if line.hasSuffix("assessments enabled") { return (true, line) }
        if line.hasSuffix("assessments disabled") { return (false, line) }
        return nil
    }

    /// "FileVault is On." / "FileVault is Off." — 해제 중은 꺼짐으로 본다. "FileVault is On." 다음 줄에 해제 중이 올 수 있어 그것부터
    /// 본다(설계 리뷰 L1). 암호화 중은 켜짐.
    static func parseFileVault(_ text: String) -> (on: Bool, line: String)? {
        if let line = firstLine(text, containing: "Decryption in progress") { return (false, line) }
        if let line = firstLine(text, containing: "Encryption in progress") { return (true, line) }
        guard let line = firstLine(text, containing: "FileVault is") else { return nil }
        if line.hasPrefix("FileVault is On") { return (true, line) }
        if line.hasPrefix("FileVault is Off") { return (false, line) }
        return nil
    }

    /// "Firewall is disabled. (State = 0)" — State 1(켜짐)·2(모두 차단)는 켜짐.
    static func parseFirewall(_ text: String) -> (on: Bool, line: String)? {
        guard let line = firstLine(text, containing: "(State = "),
              let start = line.range(of: "(State = ")?.upperBound,
              let end = line[start...].firstIndex(of: ")"),
              let state = Int(line[start..<end]) else { return nil }
        return (state > 0, line)
    }

    /// "XProtect launch scans: enabled" / "XProtect background scans: disabled".
    static func parseXProtectStatus(_ text: String) -> (launch: (on: Bool, line: String)?, background: (on: Bool, line: String)?) {
        func scan(_ label: String) -> (on: Bool, line: String)? {
            guard let line = firstLine(text, containing: label) else { return nil }
            if line.hasSuffix(": enabled") { return (true, line) }
            if line.hasSuffix(": disabled") { return (false, line) }
            return nil
        }
        return (scan("XProtect launch scans:"), scan("XProtect background scans:"))
    }

    /// "Version: 5377 Installed: 2026-11-23 01:21:13 +0000".
    static func parseXProtectVersion(_ text: String) -> (version: String, installed: Date?)? {
        guard let line = firstLine(text, containing: "Version:"),
              let versionStart = line.range(of: "Version:")?.upperBound else { return nil }
        let rest = line[versionStart...].trimmingCharacters(in: .whitespaces)
        let version = String(rest.prefix { !$0.isWhitespace })
        guard !version.isEmpty else { return nil }
        var installed: Date?
        if let installedStart = line.range(of: "Installed:")?.upperBound {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
            installed = formatter.date(from: line[installedStart...].trimmingCharacters(in: .whitespaces))
        }
        return (version, installed)
    }

    /// `mdmclient QuerySecurityInfo`의 `NSDictionary` 설명에서 두 키만 읽는다(Q84 — 사용자 실측 형식: `SecureBootLevel = full;`,
    /// `AuthenticatedRootVolumeEnabled = 1;`). 값의 따옴표는 벗긴다.
    static func parseSecurityInfo(_ text: String) -> (secureBootLevel: String?, authenticatedRoot: Bool?) {
        func value(_ key: String) -> String? {
            for line in text.split(whereSeparator: \.isNewline) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(key + " = "), trimmed.hasSuffix(";") else { continue }
                let raw = trimmed.dropFirst(key.count + 3).dropLast()
                return raw.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            }
            return nil
        }
        let level = value("SecureBootLevel").flatMap { $0.isEmpty ? nil : $0 }
        let root = value("AuthenticatedRootVolumeEnabled").flatMap { $0 == "1" ? true : $0 == "0" ? false : nil }
        return (level, root)
    }

    /// "boot-args\t-v amfi_get_out_of_my_way=1" → 이름 뒤의 값.
    static func parseBootArgs(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        guard line.hasPrefix("boot-args") else { return line.trimmingCharacters(in: .whitespaces) }
        return line.dropFirst("boot-args".count).trimmingCharacters(in: .whitespaces)
    }

    /// 서드파티 kext = 보조 묶음(aux — 서드파티뿐, 이름으로 거르지 않는다) ∪ (전체 − 부팅 묶음 중 `com.apple.`이 아닌 것).
    /// 묶음 이름 하나만 믿지 않는다 — 이 맥에서 없는 이름(`bogus`)은 전체 목록을 낸다(WO-15 재리뷰 실측). aux가 이름을 못 알아들어 전체를
    /// 내면 서드파티 판단을 버리고 두 번째 길로만 본다. 전체·부팅 묶음이 비면(커널은 늘 부팅 묶음에 있다) 확인 못 함(nil).
    /// 시스템 묶음(Intel의 Apple kext)은 두 번째 길에서 `com.apple.` 이름으로 거른다.
    static func thirdPartyKexts(all: [String: String], boot: [String: String], aux: [String: String]) -> [String: String]? {
        guard !all.isEmpty, !boot.isEmpty else { return nil }
        let auxIsReal = aux.count < all.count
        var kexts = auxIsReal ? aux.filter { boot[$0.key] == nil } : [:]
        for (bundleID, version) in all where boot[bundleID] == nil && !bundleID.hasPrefix("com.apple.") {
            kexts[bundleID] = version
        }
        return kexts
    }

    /// `kmutil showloaded … --list-only`: `색인 참조 주소 크기 고정크기 번들ID (버전) UUID <연결>`. 번들 ID는 "(버전)" 바로 앞 칸이다.
    static func parseLoadedKexts(_ text: String) -> [String: String] {
        var kexts: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let index = fields.firstIndex(where: { $0.hasPrefix("(") && $0.hasSuffix(")") }), index > 0 else { continue }
            let bundleID = String(fields[index - 1])
            guard bundleID.contains(".") else { continue }
            kexts[bundleID] = String(fields[index].dropFirst().dropLast())
        }
        return kexts
    }

    /// 없는 키는 기본값(켜짐)이다 — 이 맥에는 `AutomaticCheckEnabled`가 없다(WO-15 실측).
    static func softwareUpdateValue(_ plist: ParsedValue, key: String) -> (on: Bool, line: String)? {
        guard case .object(let object) = plist else { return nil }
        guard let raw = object[key] else { return (true, "\(key) 없음 — 기본값(켜짐)") }
        return bool(raw).map { ($0, "\(key) = \($0)") }
    }

    static func bool(_ value: ParsedValue?) -> Bool? {
        switch value {
        case .bool(let value): value
        case .int(let value): value != 0
        case .string(let value): ["1", "true", "yes"].contains(value.lowercased()) ? true : ["0", "false", "no"].contains(value.lowercased()) ? false : nil
        default: nil
        }
    }

    private static func firstLine(_ text: String, containing needle: String) -> String? {
        text.split(whereSeparator: \.isNewline).first { $0.contains(needle) }.map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

extension ParsedValue {
    fileprivate subscript(key: String) -> ParsedValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }
}
