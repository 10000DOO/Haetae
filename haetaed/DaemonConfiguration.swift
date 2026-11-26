import Foundation
import HaetaeChecks
import HaetaeShared
import os
import Security

enum Log {
    static let listener = Logger(subsystem: CodeRequirements.daemonIdentifier, category: "listener")
    static let service = Logger(subsystem: CodeRequirements.daemonIdentifier, category: "service")
}

/// 데몬 시작 때 한 번 만든다. `appRequirement`가 nil이면 모든 연결을 거부한다(fail-closed).
struct DaemonConfiguration: Sendable {
    let appRequirement: String?
    /// 디스크의 새 빌드가 진짜인지 볼 때 쓴다(자기 실행 파일의 요구사항).
    let daemonRequirement: String?
    let build: Int
    let variant: CodeRequirements.Variant
    /// 해석 서비스 요구사항을 만들지 못하면 `.unavailable`이다(WO-50).
    let parser: IsolatedParser

    static var currentVariant: CodeRequirements.Variant {
        #if DEBUG
        .debug
        #else
        .release
        #endif
    }

    static func load() -> DaemonConfiguration {
        let variant = currentVariant
        let identity: SelfIdentity
        do {
            // 실행 파일에 내장된 __info_plist(서명에 묶여 있음)를 읽는다. 식별자로 자기 것인지 확인한다.
            identity = try SelfIdentity.load(identifier: CodeRequirements.daemonIdentifier)
        } catch {
            Log.listener.fault("자기 신원 확인 실패 (\(String(describing: error), privacy: .public)) — 모든 연결 거부")
            return DaemonConfiguration(appRequirement: nil, daemonRequirement: nil, build: 0, variant: variant, parser: .unavailable)
        }
        return DaemonConfiguration(
            appRequirement: compiled("앱") { try CodeRequirements.app(teamID: identity.teamID, minBuild: identity.minBuild, variant: variant) },
            daemonRequirement: compiled("데몬") { try CodeRequirements.daemon(teamID: identity.teamID, minBuild: identity.minBuild, variant: variant) },
            build: identity.build, variant: variant,
            parser: compiled("해석 서비스") { try CodeRequirements.parser(teamID: identity.teamID, minBuild: identity.minBuild, variant: variant) }
                .map(IsolatedParser.init(serviceRequirement:)) ?? .unavailable
        )
    }

    /// 디스크에 있는 자기 실행 파일이 더 새 빌드인지(D20). 새 빌드는 데몬이 모든 `collect`를 거절하고 끊긴 연결을 세지 않게 만들므로
    /// 서명까지 확인한다 — 가짜 plist 하나로 그 상태를 만들지 못하게(재리뷰 보안 L-1). 실행 파일의 내장 plist를 본다
    /// (`Bundle.main.bundleURL/Contents/Info.plist`는 앱의 것이다). 서명 확인은 plist가 더 높다고 할 때만 한다(끊긴 연결마다 돌지 않게).
    func hasNewerBuildOnDisk() -> Bool {
        guard let url = Bundle.main.executableURL,
              let info = CFBundleCopyInfoDictionaryForURL(url as CFURL) as? [String: Any],
              CollectCoordinator.isNewerBuild(onDisk: (info["CFBundleVersion"] as? String).flatMap(Int.init), running: build),
              let daemonRequirement else { return false }
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var signing: CFDictionary?
        guard unsafe SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              unsafe SecRequirementCreateWithString(daemonRequirement as CFString, [], &requirement) == errSecSuccess, let requirement,
              SecStaticCodeCheckValidity(code, [], requirement) == errSecSuccess,
              unsafe SecCodeCopySigningInformation(code, [], &signing) == errSecSuccess,
              let plist = (signing as? [String: Any])?[kSecCodeInfoPList as String] as? [String: Any] else {
            Log.listener.error("디스크의 새 빌드가 서명 확인을 통과하지 못함 — 무시")
            return false
        }
        // 서명에 묶인 plist의 값으로 다시 본다(확인과 읽기 사이의 바꿔치기를 막는다).
        return CollectCoordinator.isNewerBuild(onDisk: (plist["CFBundleVersion"] as? String).flatMap(Int.init), running: build)
    }

    /// NSXPC는 문법이 틀린 요구사항을 받으면 예외로 프로세스를 죽인다. 컴파일되는 것만 돌려준다.
    private static func compiled(_ peer: String, _ make: () throws -> String) -> String? {
        do {
            let requirement = try make()
            let status = CodeRequirements.compileStatus(requirement)
            guard status == errSecSuccess else {
                Log.listener.fault("\(peer, privacy: .public) 요구사항 컴파일 실패 (\(status))")
                return nil
            }
            return requirement
        } catch {
            Log.listener.fault("\(peer, privacy: .public) 요구사항 생성 실패 (\(String(describing: error), privacy: .public))")
            return nil
        }
    }
}

/// 본 적 있는 가장 높은 빌드(D20 되돌리기 방지, Q34 — Release만). 파일 읽기·쓰기만 하고 판단은 `CollectCoordinator`가 한다.
enum HighestBuild {
    private static let name = "highest-build"

    /// 기록된 값과 실행 중인 빌드 중 큰 것을 돌려주고, 실행 중인 빌드가 더 크면 기록을 올린다.
    /// 읽지 못하거나 숫자가 아니면 실행 중인 빌드를 돌려주고 덮어쓰지 않는다(Q68) — 이번 실행은 되돌리기를 알 수 없지만(그 파일은
    /// root만 바꿀 수 있다) 데몬이 영영 서지 않게 하고, 되돌린 데몬이 기록을 낮추지 못하게.
    static func update(running build: Int, in directory: SecureDirectory) -> Int {
        let raw: Data?
        do {
            raw = try directory.read(name, in: [], maxBytes: 32)
        } catch {
            Log.listener.fault("highest-build를 읽지 못함 (\(String(describing: error), privacy: .public))")
            return build
        }
        let recorded = raw.map { Int(String(decoding: $0, as: UTF8.self)) }
        if case .some(nil) = recorded {
            Log.listener.fault("highest-build가 숫자가 아님 — 덮어쓰지 않음")
            return build
        }
        if let recorded = recorded ?? nil, recorded >= build { return recorded }
        do {
            try directory.write(Data(String(build).utf8), to: name, in: [])
        } catch {
            Log.listener.fault("highest-build를 쓰지 못함 (\(String(describing: error), privacy: .public))")
        }
        return build
    }
}
