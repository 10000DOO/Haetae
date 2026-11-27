import Foundation
import HaetaeShared

/// 기록에 남기는 일(`ledger/events.jsonl`, 한 줄에 하나).
public enum LedgerEvent: Codable, Sendable, Equatable {
    /// 제목까지 남긴다 — 해결돼 원장에서 지워진 뒤에도 root 기록에 무엇이었는지 남게(T18).
    case detected(fingerprint: String, checkID: String, title: String)
    case acknowledged(count: Int)
    case resolved(fingerprint: String)
    /// pending이 상한을 넘어 버린 건수(Q52).
    case pendingDropped(count: Int)
    case userQuit
    /// 유효한 호출이 있던 연결이 `markUserQuit` 없이 끊긴 수(D28). 앱을 띄웠다 죽이기를 되풀이할 수 있어 묶어서 적는다(Q66과 같은 방식).
    case abnormalTermination(count: Int)
    /// 유효한 호출 없이 끊긴 연결의 수. 누구나 반복할 수 있어 묶어서 적는다(Q66 — 1분에 한 줄).
    case verificationFailedConnection(count: Int)
    case settingWeakened(String)
    /// 시작할 때 자기 번들 검사가 실패했다(D20).
    case selfIntegrityFailed(String)
    /// 지금 돌리지 않는 검사의 기록을 치웠다(WO-56). 알림 완료 건 수(지문마다 `resolved`도 따로 남는다)와 버린 pending 수 —
    /// 상한 때문에 버린 것(`pendingDropped`)과 기록상 구분되게(T18).
    case checkRetired(checkID: String, resolved: Int, droppedPending: Int)
    /// 실행 중인 빌드가 본 적 있는 가장 높은 빌드보다 낮다 — 모든 요청을 거부한다(D20).
    case rolledBack(running: Int, highest: Int)
}

/// 데몬이 가진 탐지 원장(D12·D18·D24). 사용자별로 pending(ack 전)과 알림 완료(ack 후)를 나눠 둔다.
/// 앱 쪽에는 지문 원본을 두지 않는다(D18) — 같은 사용자 권한의 악성코드가 미리 심어 알림을 막지 못하게.
///
/// 메모리가 기준이다. 디스크에 쓰지 못해도 결과는 그대로 돌려주고 `persistenceFailure`에 남긴다 —
/// 디스크가 꽉 차도 탐지는 앱에 가야 한다. `CheckRunner`가 이것을 상태 Finding으로 올린다.
public actor FindingLedger {
    /// 형식이 바뀌면 올린다. 읽을 수 없으면 비우고 다시 시작한다(D21).
    public static let schemaVersion = 1
    static let maxStateBytes = 64_000_000
    /// 응답 하나에 보낼 수 있는 만큼(Q52). ack를 막고 탐지를 쏟아내도 원장이 다시 읽지 못할 만큼 커지지 않게.
    static let maxPendingPerUser = HaetaeLimits.maxFindingsPerReply
    /// 넘치면 가장 오래 전에 ack한 것부터 지운다 — 아직 있으면 다시 알릴 뿐 숨지는 않는다.
    static let maxNotifiedPerUser = HaetaeLimits.maxNotifiedSummaries
    /// 기록 파일 하나의 상한. 넘으면 `events.jsonl.1`로 넘긴다(두 파일 합쳐 64MB).
    static let maxEventFileBytes = 32_000_000

    /// 알림 완료 건. Finding을 통째로 둔다 — 패널의 `risks.json`(사용자 소유)이 지워져도 다시 보낼 수 있게(Q53, T18).
    private struct Notified: Codable {
        var finding: Finding
        var at: Date
    }

    private struct UserLedger: Codable {
        var pending: [String: Finding] = [:]
        var notified: [String: Notified] = [:]
        var lastSuccess: [String: Date] = [:]
        /// 최근 결과(오래된 것부터, `true`가 실패, `failureWindow`개까지). 뒤에 더한 필드라 옛 `state.json`에는 없다
        /// (Optional이 아니면 디코딩이 실패해 원장을 통째로 비운다).
        var recentFailures: [String: [Bool]]?
        /// 앱이 마지막으로 결과를 받았다고 알린(ack) 시각과, 그 뒤로 검사 공백을 알릴 일이 있었는지(Q31·Q67). 데몬이 다시 떠도
        /// 알려야 해서 디스크에 둔다.
        var lastDelivered: Date?
        var scanGapPending: Bool?
    }

    private struct State: Codable {
        var schemaVersion = FindingLedger.schemaVersion
        /// 키는 uid(JSON 사전 키는 문자열).
        var users: [String: UserLedger] = [:]
    }

    private struct EventLine: Codable {
        let at: Date
        let uid: uid_t?
        let event: LedgerEvent
    }

    /// 정리할 때는 시각만 읽는다 — `LedgerEvent`의 모양이 바뀌어도 옛 기록을 버리지 않게.
    private struct EventTime: Decodable {
        let at: Date
    }

    private static let folder = ["ledger"]
    private static let eventFiles = ["events.jsonl", "events.jsonl.1"]
    private let directory: SecureDirectory
    private let now: @Sendable () -> Date
    private var state: State

    /// 디스크에 쓰지 못한 이유. 뒤의 쓰기가 성공해도 지우지 않는다 — 기록 파일만 계속 실패하는 것(T18)이 묻히지 않게.
    private var persistenceFailure: SecureDirectoryError?

    /// 이번 실행 동안 생긴 저장 실패를 꺼내고 비운다(`CheckRunner`가 실행마다 한 번).
    public func takePersistenceFailure() -> SecureDirectoryError? {
        defer { persistenceFailure = nil }
        return persistenceFailure
    }

    /// - Parameter now: 테스트에서 시각을 주입한다.
    public init(directory: SecureDirectory, now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory
        self.now = now
        // 읽을 수 없으면(상한 초과·권한 이상·깨짐·형식 버전 포함) 비우고 다시 시작한다(D21) — 데몬이 영영 뜨지 못하게 되지 않게.
        // 옛 파일은 `state.json.bad`로 옮겨 두고 실패를 남긴다 — 다음 저장이 흔적 없이 덮지 않게.
        state = State()
        do {
            guard let raw = try directory.read("state.json", in: Self.folder, maxBytes: Self.maxStateBytes) else { return }
            let saved: State = try JSONWire.decode(raw, maxBytes: Self.maxStateBytes)
            guard saved.schemaVersion == Self.schemaVersion else { throw SecureDirectoryError.untrusted }
            state = saved
        } catch {
            persistenceFailure = error as? SecureDirectoryError ?? .system(EIO)
            try? directory.rename("state.json", to: "state.json.bad", in: Self.folder)
        }
    }

    /// 이번 검사 결과에서 보낼 것을 고른다: 알림을 마친 지문은 빼고, 새 건은 pending에 넣는다.
    /// ack 전의 pending은 이번에 보이지 않아도 다시 보낸다(D24) — 응답 직후 앱을 죽이고 흔적을 지우는 공격을 막는다.
    /// - Parameter protecting: 상한을 넘어도 버리지 않을 checkID. "기록 상한 초과" 경고는 가장 새로운 높음이라, 지키지 않으면
    ///   자기가 먼저 버려져 넘친 것을 알리지 못한다.
    /// - Returns: 보낼 것, pending 상한 때문에 버린 건수, 버린 Finding의 checkID. 건수가 0이 아니면 검사 쪽이
    ///   "기록 상한 초과" 높음 Finding을 내고(Q52), 그 검사들은 기준값 확정과 `lastSuccess`에서 뺀다(버린 탐지가 정상으로 굳지 않게).
    public func filterNew(_ findings: [Finding], uid: uid_t, protecting: Set<String> = []) -> (findings: [Finding], dropped: Int, droppedChecks: Set<String>) {
        var user = state.users[Self.key(uid), default: UserLedger()]
        var events: [LedgerEvent] = []
        for var finding in findings where user.notified[finding.fingerprint] == nil {
            if let existing = user.pending[finding.fingerprint] {
                // 처음 본 시각을 지킨다 — 한 실행의 Finding은 시각이 같아, 덮어쓰면 버리는 순서(Q52)가 먼저 잡힌 것을 못 알아본다.
                finding.observedAt = existing.observedAt
            } else {
                events.append(.detected(fingerprint: finding.fingerprint, checkID: finding.checkID, title: finding.title))
            }
            user.pending[finding.fingerprint] = finding
        }
        var dropped = 0
        var droppedChecks: Set<String> = []
        let excess = user.pending.count - Self.maxPendingPerUser
        if excess > 0 {
            // 낮은 수준부터, 같은 수준이면 새 것부터 버린다 — 먼저 잡힌 탐지를 뒤에 쏟아낸 건으로 밀어내지 못하게.
            let victims = user.pending.values.filter { !protecting.contains($0.checkID) }.sorted {
                $0.ruleLevel != $1.ruleLevel ? $0.ruleLevel.rank < $1.ruleLevel.rank : $0.observedAt > $1.observedAt
            }.prefix(excess)
            for finding in victims {
                user.pending[finding.fingerprint] = nil
                droppedChecks.insert(finding.checkID)
            }
            dropped = victims.count
            events.append(.pendingDropped(count: dropped))
        }
        state.users[Self.key(uid)] = user
        save()
        record(events, uid: uid)
        return (Array(user.pending.values), dropped, droppedChecks)
    }

    /// 알림을 마친 지문. 검사별 상한 앞에서 거르는 데 쓴다(Finding을 복사하지 않게 지문만).
    public func notifiedFingerprints(uid: uid_t) -> Set<String> {
        guard let user = state.users[Self.key(uid)] else { return [] }
        return Set(user.notified.keys)
    }

    /// 알림을 마쳤고 아직 해결되지 않은 건(Q53). 응답마다 함께 보내 앱이 패널을 다시 만들 수 있게 한다(WO-12·13).
    public func unresolvedNotified(uid: uid_t) -> [Finding] {
        state.users[Self.key(uid)]?.notified.values.map(\.finding) ?? []
    }

    /// pending에 있던 지문만 알림 완료로 바꾼다 — 앱이 아무 지문이나 ack해 앞으로의 탐지를 미리 숨기지 못하게.
    /// ack는 앱이 `collect` 결과를 받았다는 뜻이기도 하다(앱은 탐지가 0건이어도 `collect`마다 ack한다 — Q67). 그래서 검사 공백 표시를
    /// 여기서 지우고 공백의 시작점을 지금으로 옮긴다. 응답을 만들 때 지우면, 앱이 받기 직전마다 앱을 죽여 공백을 짧게 보이게 할 수 있다.
    /// - Returns: 실제로 알림 완료가 된 지문.
    @discardableResult
    public func acknowledge(_ fingerprints: [String], uid: uid_t) -> [String] {
        var user = state.users[Self.key(uid), default: UserLedger()]
        let at = now()
        var acknowledged: [String] = []
        for fingerprint in fingerprints {
            guard let finding = user.pending.removeValue(forKey: fingerprint) else { continue }
            user.notified[fingerprint] = Notified(finding: finding, at: at)
            acknowledged.append(fingerprint)
        }
        if user.notified.count > Self.maxNotifiedPerUser {
            let oldest = user.notified.sorted { $0.value.at < $1.value.at }.prefix(user.notified.count - Self.maxNotifiedPerUser)
            for (fingerprint, _) in oldest { user.notified[fingerprint] = nil }
        }
        user.lastDelivered = at
        user.scanGapPending = nil
        state.users[Self.key(uid)] = user
        save()
        if !acknowledged.isEmpty { record([.acknowledged(count: acknowledged.count)], uid: uid) }
        return acknowledged
    }

    /// 기준값을 확정해도 되는지(D24): 그 사용자의 그 검사에 ack되지 않은 Finding이 없어야 한다.
    public func hasPending(checkID: String, uid: uid_t) -> Bool {
        state.users[Self.key(uid)]?.pending.values.contains { $0.checkID == checkID } ?? false
    }

    /// ack되지 않은 Finding이 남은 checkID. ack 뒤 확정(`CheckRunner.confirmAfterAck`)이 한 번에 묻는다.
    public func pendingCheckIDs(uid: uid_t) -> Set<String> {
        Set(state.users[Self.key(uid)]?.pending.values.map(\.checkID) ?? [])
    }

    /// 알림을 마쳤는데 이번에 성공한 검사에서 보이지 않은 지문. 기록에서 빼고 돌려준다(앱이 해결됨으로 표시).
    /// 실패한 검사의 지문은 건드리지 않는다 — 검사가 실패해 안 보인 것을 해결로 보면 안 된다(T12).
    public func resolved(current: Set<String>, succeededChecks: Set<String>, uid: uid_t) -> [String] {
        var user = state.users[Self.key(uid), default: UserLedger()]
        let gone = user.notified.filter { succeededChecks.contains($0.value.finding.checkID) && !current.contains($0.key) }.map(\.key)
        guard !gone.isEmpty else { return [] }
        for fingerprint in gone { user.notified[fingerprint] = nil }
        state.users[Self.key(uid)] = user
        save()
        record(gone.map { .resolved(fingerprint: $0) }, uid: uid)
        return gone
    }

    /// 지금 돌리지 않는 검사(지웠거나 이름을 바꾼 검사, Release에는 없는 Debug 전용 검사)의 기록을 치운다(WO-56, Q83).
    /// 해결 판정(`resolved`)은 이번에 성공한 검사만 보므로, 이것이 없으면 그런 검사의 알림 완료 건이 30일 정리 전까지 남는다.
    /// 알림 완료 건은 해결로 돌려주고(앱이 패널에서 내린다), pending은 버린다 — 다시 나타날 수 없는 검사의 옛 탐지를 새로 알리지 않게.
    /// - Parameter known: 데몬에 컴파일된 검사 id와 내부 상태 id만 넘긴다. 설정·패턴 팩으로 "끈 검사"를 빼서 넘기면 끄는 것만으로
    ///   그 검사의 진짜 위험이 해결로 넘어간다(WO-56 보안 리뷰).
    /// - Returns: 해결로 보낼 지문과, pending을 버린 checkID(부른 쪽이 그 pending 기준값을 치운다 — `purge`와 같은 이유).
    public func forgetChecks(notIn known: Set<String>, uid: uid_t) -> (resolved: [String], droppedChecks: Set<String>) {
        guard var user = state.users[Self.key(uid)] else { return ([], []) }
        let gone = user.notified.filter { !known.contains($0.value.finding.checkID) }
        let stale = user.pending.filter { !known.contains($0.value.checkID) }
        guard !gone.isEmpty || !stale.isEmpty else { return ([], []) }
        for fingerprint in gone.keys { user.notified[fingerprint] = nil }
        for fingerprint in stale.keys { user.pending[fingerprint] = nil }
        state.users[Self.key(uid)] = user
        save()
        let resolvedByCheck = Dictionary(grouping: gone.values, by: \.finding.checkID).mapValues(\.count)
        let droppedByCheck = Dictionary(grouping: stale.values, by: \.checkID).mapValues(\.count)
        var events = gone.keys.map { LedgerEvent.resolved(fingerprint: $0) }
        for checkID in Set(resolvedByCheck.keys).union(droppedByCheck.keys).sorted() {
            events.append(.checkRetired(checkID: checkID, resolved: resolvedByCheck[checkID] ?? 0, droppedPending: droppedByCheck[checkID] ?? 0))
        }
        record(events, uid: uid)
        return (Array(gone.keys), Set(droppedByCheck.keys))
    }

    /// 여러 줄을 한 번에 쓴다(폴더 열기·`fsync` 한 번).
    public func record(_ events: [LedgerEvent], uid: uid_t?) {
        guard !events.isEmpty else { return }
        let at = now()
        do {
            var lines = Data()
            for event in events {
                lines.append(try JSONWire.encode(EventLine(at: at, uid: uid, event: event)))
                lines.append(UInt8(ascii: "\n"))
            }
            try directory.append(lines, to: Self.eventFiles[0], in: Self.folder, rotateAt: Self.maxEventFileBytes)
        } catch {
            persistenceFailure = error as? SecureDirectoryError ?? .system(EIO)
        }
    }

    /// `age`보다 오래된 알림 완료·pending과 기록 줄을 지운다(R11 — 30일). 지운 알림 완료 건이 아직 있으면 다시 알린다.
    /// 앱이 ack하지 않으면 pending이 끝없이 쌓이므로 오래된 pending도 지운다.
    /// - Returns: 사용자마다 pending을 지운 checkID. 그 검사의 pending 기준값에는 알리지 못한 항목이 들어 있을 수 있어 부른 쪽이
    ///   `BaselineStore.discardPending`으로 치운다(WO-12) — 안 치우면 뒤의 ack 확정으로 정상으로 굳는다.
    @discardableResult
    public func purge(olderThan age: TimeInterval) -> [uid_t: Set<String>] {
        let cutoff = now().addingTimeInterval(-age)
        var purgedPending: [uid_t: Set<String>] = [:]
        for (key, var user) in state.users {
            user.notified = user.notified.filter { $0.value.at >= cutoff }
            let expired = Set(user.pending.values.filter { $0.observedAt < cutoff }.map(\.checkID))
            if !expired.isEmpty, let uid = uid_t(key) { purgedPending[uid] = expired }
            user.pending = user.pending.filter { $0.value.observedAt >= cutoff }
            state.users[key] = user
        }
        save()
        for name in Self.eventFiles {
            do {
                guard let raw = try directory.read(name, in: Self.folder, maxBytes: Self.maxEventFileBytes) else { continue }
                // 시각을 읽지 못하는 줄은 끊긴 마지막 줄 정도뿐이라 버린다.
                let kept = raw.split(separator: UInt8(ascii: "\n")).filter { line in
                    (try? JSONWire.decode(Data(line), maxBytes: Self.maxEventFileBytes) as EventTime).map { $0.at >= cutoff } ?? false
                }
                var rewritten = Data(kept.joined(separator: [UInt8(ascii: "\n")]))
                if !kept.isEmpty { rewritten.append(UInt8(ascii: "\n")) }
                try directory.write(rewritten, to: name, in: Self.folder)
            } catch {
                persistenceFailure = error as? SecureDirectoryError ?? .system(EIO)
            }
        }
        return purgedPending
    }

    /// 마지막으로 성공한 검사 시각(Q50 — 사용자별). 로그 검사는 이 뒤만 본다.
    public func lastSuccess(checkID: String, uid: uid_t) -> Date? {
        state.users[Self.key(uid)]?.lastSuccess[checkID]
    }

    /// 그 실행의 Finding을 `filterNew`로 pending에 넣은 **뒤에** 부른다 — 먼저 부르면 도중에 꺼졌을 때 그 구간을 다시 보지 못한다(WO-11).
    /// 성공한 검사를 한 번에 넘긴다(`state.json`을 한 번만 쓰게).
    public func setLastSuccess(_ date: Date, checkIDs: some Sequence<String>, uid: uid_t) {
        for checkID in checkIDs {
            state.users[Self.key(uid), default: UserLedger()].lastSuccess[checkID] = date
        }
        save()
    }

    /// 최근 몇 번의 결과로 실패 수준을 정하는지(Q58).
    static let failureWindow = 5

    /// 실패를 하나 남기고 최근 `failureWindow`번 중 실패 수를 돌려준다(Q58 — 연속 횟수로 세면 실패·실패·성공을 되풀이해
    /// 높음을 영영 피할 수 있다). 디스크에 바로 둔다 — 메모리에만 두거나 실행 끝에 모아 두면 앱을 죽여 데몬을 내리는 것만으로
    /// 횟수가 오르지 않는다(T12).
    public func noteFailure(_ key: String, uid: uid_t) -> Int {
        var user = state.users[Self.key(uid), default: UserLedger()]
        var all = user.recentFailures ?? [:]
        let history = Array((all[key, default: []] + [true]).suffix(Self.failureWindow))
        all[key] = history
        user.recentFailures = all
        state.users[Self.key(uid)] = user
        save()
        return history.count(where: { $0 })
    }

    /// 성공을 남긴다. 최근 결과에 실패가 없어지면 기록을 지운다(실패한 적 없는 검사는 기록이 없다).
    public func noteSuccesses(_ keys: some Sequence<String>, uid: uid_t) {
        guard var all = state.users[Self.key(uid)]?.recentFailures else { return }
        var changed = false
        for key in keys {
            guard let history = all[key] else { continue }
            let next = Array((history + [false]).suffix(Self.failureWindow))
            all[key] = next.contains(true) ? next : nil
            changed = true
        }
        guard changed else { return }
        state.users[Self.key(uid)]?.recentFailures = all
        save()
    }

    /// 검사 공백을 알릴 일이 생겼다(Q31 — 비정상 종료, WO-40의 정지 의심). 언제 부를지는 `CollectCoordinator`가 정한다.
    public func markScanGap(uid: uid_t) {
        // 이미 표시돼 있으면 쓰지 않는다 — 끊김을 되풀이해 `state.json` 전체를 계속 다시 쓰게 하지 못하게.
        guard state.users[Self.key(uid)]?.scanGapPending != true else { return }
        var user = state.users[Self.key(uid), default: UserLedger()]
        user.scanGapPending = true
        // 앱이 아직 한 번도 받았다고 알리지 않았으면 지금을 시작점으로 둔다 — 설치 직후부터 첫 ack 전에 앱을 계속 죽이면 공백을 재지
        // 못한 채 첫 ack에 지워진다(Q67 확인 Low).
        if user.lastDelivered == nil { user.lastDelivered = now() }
        state.users[Self.key(uid)] = user
        save()
    }

    /// 알릴 일이 있었으면 앱이 마지막으로 결과를 받은 때부터 지금까지(검사 공백). 표시는 지우지 않는다 — 앱이 받았다고 알릴 때
    /// (`acknowledge`) 지운다(Q67).
    public func scanGap(uid: uid_t) -> TimeInterval? {
        guard let user = state.users[Self.key(uid)], user.scanGapPending == true else { return nil }
        let at = now()
        return user.lastDelivered.map { max(0, at.timeIntervalSince($0)) }
    }

    /// 다시 읽지 못할 크기면 쓰지 않는다 — 써지기는 하는데 다음 시작 때 읽지 못하는 상태를 만들지 않게.
    /// 사용자가 여럿이면 합이 상한을 넘을 수 있어, 가장 오래 전에 ack한 것부터 덜어 낸다(아직 있으면 다시 알릴 뿐 숨지 않는다).
    private func save() {
        do {
            var encoded = try JSONWire.encode(state)
            while encoded.count > Self.maxStateBytes {
                let total = state.users.values.reduce(0) { $0 + $1.notified.count }
                // 넘친 비율만큼 한 번에 덜어 낸다 — 큰 상태를 수십 번 다시 인코딩하지 않게.
                let share = total * (encoded.count - Self.maxStateBytes) / encoded.count + 1
                guard evictOldestNotified(max(200, share)) > 0 else { break }
                encoded = try JSONWire.encode(state)
            }
            guard encoded.count <= Self.maxStateBytes else { throw SecureDirectoryError.tooLarge }
            try directory.write(encoded, to: "state.json", in: Self.folder)
        } catch {
            persistenceFailure = error as? SecureDirectoryError ?? .system(EIO)
        }
    }

    /// 모든 사용자의 알림 완료 건 중 가장 오래 전에 ack한 것 `count`개를 지운다. 지운 개수를 돌려준다.
    private func evictOldestNotified(_ count: Int) -> Int {
        let oldest = state.users.flatMap { key, user in user.notified.map { (key, $0.key, $0.value.at) } }
            .sorted { $0.2 < $1.2 }
            .prefix(count)
        for (key, fingerprint, _) in oldest { state.users[key]?.notified[fingerprint] = nil }
        return oldest.count
    }

    private static func key(_ uid: uid_t) -> String { String(uid) }
}
