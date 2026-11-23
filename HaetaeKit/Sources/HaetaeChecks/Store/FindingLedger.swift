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
    case abnormalTermination
    case verificationFailedConnection
    case settingWeakened(String)
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
    static let maxNotifiedPerUser = 2_000
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
    /// - Returns: 보낼 것과, pending 상한 때문에 버린 건수. 0이 아니면 검사 쪽이 "기록 상한 초과" 높음 Finding을 낸다(Q52).
    public func filterNew(_ findings: [Finding], uid: uid_t) -> (findings: [Finding], dropped: Int) {
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
        let dropped = max(0, user.pending.count - Self.maxPendingPerUser)
        if dropped > 0 {
            // 낮은 수준부터, 같은 수준이면 새 것부터 버린다 — 먼저 잡힌 탐지를 뒤에 쏟아낸 건으로 밀어내지 못하게.
            let order: [RiskLevel: Int] = [.low: 0, .medium: 1, .high: 2]
            let victims = user.pending.values.sorted {
                let left = order[$0.ruleLevel, default: 0], right = order[$1.ruleLevel, default: 0]
                return left != right ? left < right : $0.observedAt > $1.observedAt
            }.prefix(dropped)
            for finding in victims { user.pending[finding.fingerprint] = nil }
            events.append(.pendingDropped(count: dropped))
        }
        state.users[Self.key(uid)] = user
        save()
        record(events, uid: uid)
        return (Array(user.pending.values), dropped)
    }

    /// 알림을 마쳤고 아직 해결되지 않은 건(Q53). 응답마다 함께 보내 앱이 패널을 다시 만들 수 있게 한다(WO-12·13).
    public func unresolvedNotified(uid: uid_t) -> [Finding] {
        state.users[Self.key(uid)]?.notified.values.map(\.finding) ?? []
    }

    /// pending에 있던 지문만 알림 완료로 바꾼다 — 앱이 아무 지문이나 ack해 앞으로의 탐지를 미리 숨기지 못하게.
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
        state.users[Self.key(uid)] = user
        save()
        if !acknowledged.isEmpty { record([.acknowledged(count: acknowledged.count)], uid: uid) }
        return acknowledged
    }

    /// 기준값을 확정해도 되는지(D24): 그 사용자의 그 검사에 ack되지 않은 Finding이 없어야 한다.
    public func hasPending(checkID: String, uid: uid_t) -> Bool {
        state.users[Self.key(uid)]?.pending.values.contains { $0.checkID == checkID } ?? false
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
    public func purge(olderThan age: TimeInterval) {
        let cutoff = now().addingTimeInterval(-age)
        for (key, var user) in state.users {
            user.notified = user.notified.filter { $0.value.at >= cutoff }
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
