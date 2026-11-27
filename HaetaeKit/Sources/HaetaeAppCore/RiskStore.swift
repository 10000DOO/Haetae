import Foundation
import HaetaeShared

/// 패널이 보는 판정 기록(`~/Library/Application Support/Haetae/risks.json`, D12). 원본 기록은 데몬 원장이고 이것은 보기용 캐시다 —
/// 사용자 소유라 같은 사용자 권한으로 지우거나 바꿀 수 있다. 그래서 알릴지·ack할지는 이 기록으로 정하지 않고(파이프라인이 이 실행의
/// 메모리로 정한다), 파일에서 읽은 판정은 믿지 않으며(규칙 수준으로 되돌림, Q71), 내용은 데몬 응답으로 확인되기 전까지 믿지 않는다
/// (`unverified` — 알림 완료 요약의 제목·검사·규칙 수준·증거 해시와 대조, Q53·Q69·Q71). 바꾸는 함수는 메모리만 바꾸고 `commit()`이 한 번에 쓴다 — 한 번의 검사에서 파일을 여러 번 다시 쓰지 않게.
@MainActor
public final class RiskStore {
    public static let schemaVersion = 1
    static let maxFileBytes = 32_000_000
    /// 해결된 것의 상한. 쏟아냈다 사라지기를 되풀이해 파일을 키우지 못하게, 넘치면 가장 오래 전에 해결된 것부터 지운다.
    static let maxResolved = 5_000
    /// 해결된 것은 이만큼 지나면 지운다(R11). 아직 있는 것은 지우지 않는다 — 데몬이 알림 완료 요약에서 빼면(해결·30일 정리) 해결로 간다.
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    private struct Stored: Codable {
        var schemaVersion: Int
        var risks: [Risk]
    }

    private let fileURL: URL
    private let now: () -> Date
    private var risks: [String: Risk] = [:]
    /// 파일에서 읽었고 이 실행에서 아직 데몬 응답(이번 findings나 알림 완료 요약)으로 확인하지 못한 지문. 심거나 바꾼 것일 수 있어,
    /// 응답이 잘렸어도 다음 맞추기에서 응답에 없으면 해결로 본다.
    private var unverified: Set<String> = []
    /// 시작할 때 파일이 있었는데 읽지 못했다(링크·크기·형식·버전). 기록은 비우고 시작했다 — 다음 응답의 요약으로 되살아난다.
    /// 시작할 때 한 번 정해지는 값이다(이번 실행에서 기록을 잃었음을 알리는 용도).
    public private(set) var loadFailed = false

    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "Haetae/risks.json")
    }

    public init(fileURL: URL = RiskStore.defaultURL, now: @escaping () -> Date = { Date() }) {
        self.fileURL = fileURL
        self.now = now
        do {
            guard let data = try Self.read(fileURL) else { return }
            let stored: Stored = try JSONWire.decode(data, maxBytes: Self.maxFileBytes)
            guard stored.schemaVersion == Self.schemaVersion else { throw CocoaError(.fileReadCorruptFile) }
            let at = now()
            // 형식이 틀린 줄은 버린다(ack로 보낼 수 없는 지문, 패널을 멈출 만큼 긴 글, 데몬이 정리하지 않은 모양의 글). 미래 시각은 지금으로 —
            // 30일 정리를 피하지 못하게.
            for var risk in stored.risks where Self.isValid(risk) && Self.isDaemonShaped(risk) {
                if let resolved = risk.resolvedAt, resolved > at { risk.resolvedAt = at }
                risks[risk.fingerprint] = Self.distrustJudgment(risk)
            }
            unverified = Set(risks.keys)
        } catch {
            loadFailed = true
        }
    }

    /// 파일에서 읽었고 아직 데몬 응답으로 확인하지 못했다 — 패널은 "확인 전"으로 보이고, WO-22는 다시 판정하지 않는다(증거가 공격자 글일
    /// 수 있다). 첫 맞추기 전까지만 true일 수 있다.
    public func isVerified(_ fingerprint: String) -> Bool {
        !unverified.contains(fingerprint)
    }

    /// 아직 있는 위험(수준이 높은 것부터, 같으면 최근 판정, 그다음 지문 — 검사마다 순서가 바뀌지 않게).
    public var activeRisks: [Risk] {
        risks.values.filter { $0.resolvedAt == nil }.sorted {
            if $0.level != $1.level { return $0.level.rank > $1.level.rank }
            if $0.judgedAt != $1.judgedAt { return $0.judgedAt > $1.judgedAt }
            return $0.fingerprint < $1.fingerprint
        }
    }

    /// 판정 결과를 넣는다. 같은 지문이면 덮는다(다시 나타난 것은 다시 아직 있는 것이 된다).
    /// - Returns: 실제로 넣은 지문. 파이프라인은 이것만 ack한다 — 형식이 틀려 버린 것을 ack하면 저장 없이 알림 완료가 된다(D24).
    @discardableResult
    public func save(_ new: [Risk]) -> Set<String> {
        var stored = Set<String>()
        for var risk in new where Self.isValid(risk) {
            risk.resolvedAt = nil
            risks[risk.fingerprint] = risk
            unverified.remove(risk.fingerprint)
            stored.insert(risk.fingerprint)
        }
        return stored
    }

    /// 데몬이 해결됐다고 보낸 지문.
    public func markResolved(_ fingerprints: [String]) {
        let at = now()
        for fingerprint in fingerprints where risks[fingerprint]?.resolvedAt == nil {
            risks[fingerprint]?.resolvedAt = at
        }
    }

    /// 데몬의 알림 완료 요약(전부)으로 기록을 맞춘다(Q69 1번).
    /// - 요약에 있는데 기록에 없거나 해결로 바뀌어 있으면 되살린다 — 증거는 없고(`restored`), 알리지 않는다(이미 알렸던 것이다).
    /// - 파일에서 읽은 것이 요약과 다르면(검사·제목·규칙 수준, 증거 해시) 요약으로 다시 만든다(Q71) — 이미 알린 높음을 그럴듯한 다른
    ///   제목·증거로 바꿔 거짓 안심을 주지 못하게.
    /// - 기록에서 아직 있는 것인데 요약에도 이번 탐지(`current`)에도 없으면 해결로 본다 — 데몬이 더는 들고 있지 않다(해결, 30일 정리,
    ///   상한으로 밀림 — 아직 있으면 다시 탐지돼 새 건으로 온다). 단,
    ///   - 이번에 실패한 검사(`failedChecks`)의 것은 해결로 보지 않는다 — 데몬도 실패한 검사의 지문은 해결로 보내지 않는다(T12).
    ///     파일에서 읽고 아직 확인 못 한 것은 예외다 — 공격자가 실패시키는 검사의 ID를 단 가짜 항목이 남지 못하게. 진짜 항목은 요약이나
    ///     이번 탐지로 오므로 잃지 않는다.
    ///   - 응답이 잘렸으면(`complete == false`) 이 실행에서 확인한 것은 해결로 보지 않는다 — 잘려 못 온 pending을 해결로 보면 다음
    ///     응답에서 새 건으로 다시 알린다. 파일에서 읽고 아직 확인 못 한 것(`unverified`)은 잘렸어도 해결로 본다 — 심은 항목이 응답이
    ///     계속 잘리는 동안 남지 못하게.
    /// - Returns: 되살린 수, 해결로 본 수.
    @discardableResult
    public func reconcile(notified: [NotifiedSummary], current: Set<String>, failedChecks: Set<String>, complete: Bool) -> (restored: Int, resolved: Int) {
        let at = now()
        var restored = 0
        for summary in notified {
            if let existing = risks[summary.fingerprint], !unverified.contains(summary.fingerprint) || Self.matches(existing, summary) {
                guard existing.resolvedAt != nil else { continue }
                risks[summary.fingerprint]?.resolvedAt = nil
            } else {
                risks[summary.fingerprint] = Self.restored(summary, at: at)
            }
            restored += 1
        }
        let confirmed = current.union(notified.map(\.fingerprint))
        var resolved = 0
        for (fingerprint, risk) in risks where risk.resolvedAt == nil && !confirmed.contains(fingerprint) {
            let isUnverified = unverified.contains(fingerprint)
            guard isUnverified || (complete && !failedChecks.contains(risk.finding.checkID)) else { continue }
            risks[fingerprint]?.resolvedAt = at
            resolved += 1
        }
        unverified.subtract(confirmed)
        return (restored, resolved)
    }

    /// 해결된 지 30일 지난 것을 지우고, 해결된 것이 상한을 넘으면 가장 오래 전에 해결된 것부터 지운다.
    public func purge() {
        let cutoff = now().addingTimeInterval(-Self.retention)
        risks = risks.filter { $0.value.resolvedAt.map { $0 >= cutoff } ?? true }
        let resolved = risks.values.filter { $0.resolvedAt != nil }
        guard resolved.count > Self.maxResolved else { return }
        for risk in oldestResolvedFirst(resolved).prefix(resolved.count - Self.maxResolved) { risks[risk.fingerprint] = nil }
    }

    /// 파일에 쓴다(상위 폴더 0700, 파일 0600, 원자적). 다시 읽을 수 있는 크기(32MB)를 넘으면 오래 전에 해결된 것부터 덜어 내고, 그래도
    /// 넘치면 오래된 것부터 증거를 비운다 — 써지기는 하는데 다음 시작 때 읽지 못하는 파일을 만들지 않게. 실패하면 던진다 — 부른 쪽은
    /// ack하지 않는다(D24).
    public func commit() throws {
        let folder = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        var data = try encoded()
        while data.count > Self.maxFileBytes {
            // 넘친 비율만큼 한 번에 덜어 낸다 — 큰 기록을 수십 번 다시 인코딩하지 않게.
            let share = max(100, risks.count * (data.count - Self.maxFileBytes) / data.count + 1)
            guard shrink(by: share) else { throw CocoaError(.fileWriteOutOfSpace) }
            data = try encoded()
        }
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func encoded() throws -> Data {
        try JSONWire.encode(Stored(schemaVersion: Self.schemaVersion, risks: Array(risks.values)))
    }

    /// 해결된 것 `count`개를 지우고, 해결된 것이 없으면 아직 있는 것 `count`개의 증거를 비운다. 줄일 것이 없으면 false.
    private func shrink(by count: Int) -> Bool {
        let resolved = risks.values.filter { $0.resolvedAt != nil }
        if !resolved.isEmpty {
            for risk in oldestResolvedFirst(resolved).prefix(count) { risks[risk.fingerprint] = nil }
            return true
        }
        // 낮은 수준·최근 판정부터 비운다 — 쏟아낸 낮음 때문에 먼저 잡힌 높음의 증거를 잃지 않게(데몬 `deliveryOrder`의 반대).
        let withEvidence = risks.values.filter { !$0.finding.evidence.isEmpty }.sorted {
            $0.level != $1.level ? $0.level.rank < $1.level.rank : $0.judgedAt > $1.judgedAt
        }
        guard !withEvidence.isEmpty else { return false }
        for risk in withEvidence.prefix(count) { risks[risk.fingerprint]?.finding.evidence = "" }
        return true
    }

    /// 줄일 때 먼저 버릴 해결 기록 순서: 확인 못 한 것(파일에서 읽은 해결 기록은 확인할 수단이 없다 — 심은 해결 기록이 진짜 기록을
    /// 밀어내지 못하게) → 오래 전에 해결된 것.
    private func oldestResolvedFirst(_ list: [Risk]) -> [Risk] {
        list.sorted {
            let (a, b) = (unverified.contains($0.fingerprint), unverified.contains($1.fingerprint))
            if a != b { return a }
            return ($0.resolvedAt ?? .distantFuture, $0.fingerprint) < ($1.resolvedAt ?? .distantFuture, $1.fingerprint)
        }
    }

    /// 링크를 따라가지 않고 일반 파일만, 상한 + 1바이트까지만 읽는다 — 크기를 본 뒤 큰 파일로 바꿔치기하거나 링크로 큰 파일을 가리켜
    /// 앱이 시작할 때마다 메모리를 다 쓰게 하지 못하게. 없으면 nil.
    private static func read(_ url: URL) throws -> Data? {
        let fd = unsafe open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard unsafe fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maxFileBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let data = try handle.read(upToCount: maxFileBytes + 1) ?? Data()
        guard data.count <= maxFileBytes else { throw CocoaError(.fileReadTooLarge) }
        return data
    }

    /// 파일에서 읽은 줄과 판정 결과의 형식(응답 검증과 같은 상한). 지문은 ack로 보내고, 글은 패널에 그대로 그린다.
    private static func isValid(_ risk: Risk) -> Bool {
        Finding.isFingerprint(risk.fingerprint) && Finding.isCheckID(risk.finding.checkID)
            && risk.finding.title.unicodeScalars.count <= HaetaeLimits.maxTitleChars
            && risk.finding.evidence.unicodeScalars.count <= HaetaeLimits.maxEvidenceChars
            && risk.reason.unicodeScalars.count <= Risk.maxReasonChars
    }

    /// 파일에서 읽은 제목·증거는 데몬이 정리한 모양이어야 한다(`Finding.displaySafe`) — 방향 제어 문자·줄바꿈·결합 문자 더미가 든 줄은
    /// 심은 것이라 버린다(데몬은 이런 글을 만들지 않는다, WO-14 2단계 리뷰 실측). 데몬 응답(`save`)에는 걸지 않는다 — 다음 버전에서
    /// 규칙을 넓히면 옛 데몬이 원장에 남긴 글이 걸려 저장·ack되지 못한다(재리뷰 설계 L1). 그렇게 저장된 줄은 다음 실행에서 버려지고 요약으로 되살아난다.
    private static func isDaemonShaped(_ risk: Risk) -> Bool {
        Finding.displaySafe(risk.finding.title, multiline: false) == risk.finding.title
            && Finding.displaySafe(risk.finding.evidence, multiline: true) == risk.finding.evidence
    }

    /// 파일에서 읽은 판정은 믿지 않는다(Q71 1번) — 수준·위험 여부는 규칙 수준으로, 이유는 고정 문구로 되돌린다. LLM이 낮춘 것은 앱이
    /// 다시 뜬 뒤 원래 수준으로 보인다(알림은 다시 하지 않는다). 바꿔치기한 "낮음·안전한 항목이에요" 같은 판정이 남지 않게.
    private static func distrustJudgment(_ risk: Risk) -> Risk {
        var risk = risk
        risk.level = risk.finding.ruleLevel
        risk.isRisk = risk.finding.ruleLevel != .low
        if risk.judgedBy != .restored { risk.judgedBy = .rule }
        risk.reason = risk.judgedBy == .restored ? restoredReason(checkID: risk.finding.checkID) : RuleOnlyJudge.reason(checkID: risk.finding.checkID)
        return risk
    }

    /// 파일에서 읽은 내용이 데몬 요약과 같은지. 증거가 비어 있으면(되살린 것, 크기 때문에 비운 것) 보여 줄 것이 없어 해시는 보지 않는다.
    private static func matches(_ risk: Risk, _ summary: NotifiedSummary) -> Bool {
        risk.finding.checkID == summary.checkID && risk.finding.title == summary.title && risk.finding.ruleLevel == summary.ruleLevel
            && (risk.finding.evidence.isEmpty || Finding.evidenceHash(risk.finding.evidence) == summary.evidenceHash)
    }

    private static func restored(_ summary: NotifiedSummary, at: Date) -> Risk {
        let finding = Finding(
            checkID: summary.checkID, title: summary.title, evidence: "", ruleLevel: summary.ruleLevel,
            fingerprint: summary.fingerprint, observedAt: summary.observedAt
        )
        return Risk(finding: finding, level: summary.ruleLevel, reason: restoredReason(checkID: summary.checkID),
                    judgedBy: .restored, judgedAt: at, isRisk: summary.ruleLevel != .low)
    }

    static func restoredReason(checkID: String) -> String {
        "기록이 지워져 데몬의 요약으로 되살렸어요 (검사: \(checkID))"
    }
}
