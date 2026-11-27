import Foundation
import HaetaeShared
import os

/// XPC 메서드 뒤의 규칙(Q23): 응답 자르기, 빈도 제한과 결과 공유, ack 확정, 연결 종료 기록, 되돌리기 방지, 검사 공백(`scanGap`),
/// 오래된 기록 정리. 데몬 타깃의 `CollectService`는 이것을 부르고 오류를 NSError로 바꾸기만 한다.
/// 파일·번들은 읽지 않는다 — `highestBuild`와 자기 번들 검사 결과는 `main`이 읽어 값으로 넘긴다(테스트에서 주입하게).
public actor CollectCoordinator {
    /// 같은 사용자의 `collect`는 이 간격에 한 번 시작한다. 그 사이 요청은 도는 실행의 결과를 같이 받는다(WO-12 4번).
    static let collectInterval = HaetaeLimits.minCollectInterval
    /// 누구나 되풀이할 수 있는 연결 사건(검증 실패 연결, 비정상 종료)을 묶어 적는 간격(Q66).
    static let batchInterval: Duration = .seconds(60)
    /// 오래된 기록 정리(R11, Q65): 데몬이 뜬 뒤 첫 `collect` 전, 그 뒤 하루마다 30일 지난 것을 지운다.
    static let purgeInterval: Duration = .seconds(24 * 60 * 60)
    static let retention: TimeInterval = 30 * 24 * 60 * 60
    /// 응답을 맞출 때 남기는 여유. 자른 뒤 채우는 `droppedFindings`·`scanGap` 숫자가 늘어나도 한도를 넘지 않게.
    static let replySlack = 1_024

    private let runner: CheckRunner
    private let ledger: FindingLedger
    private let build: Int
    /// nil이면 되돌리기 방지를 끈다(Debug, Q34).
    private let highestBuild: Int?
    private let now: @Sendable () -> ContinuousClock.Instant

    private var inFlight: [uid_t: Task<Result<Data, HaetaeXPCError>, Never>] = [:]
    private var lastStarted: [uid_t: ContinuousClock.Instant] = [:]
    private var lastPurge: ContinuousClock.Instant?
    /// 시작할 때 생긴 일. init은 원장을 기다릴 수 없어, 처음 불린 메서드가 적는다.
    private var startupEvents: [LedgerEvent] = []
    private var invalidConnections = EventBatch()
    private var abnormalTerminations: [uid_t: EventBatch] = [:]

    /// - Parameters:
    ///   - runner: 이 데몬의 유일한 `CheckRunner`. ack 확정·정리는 이것으로만 한다(실행과 같은 줄에 서야 해서).
    ///   - highestBuild: 본 적 있는 가장 높은 빌드. Release에서만 넘긴다(Q34).
    ///   - selfIntegrity: 시작할 때 본 자기 번들 검사 결과(D20). Finding은 `SelfIntegrityCheck`가 내고 여기서는 기록만 남긴다.
    ///   - now: 빈도 제한·묶기·정리 간격을 재는 시계. 테스트에서 주입한다.
    public init(
        runner: CheckRunner, ledger: FindingLedger, build: Int, highestBuild: Int?, selfIntegrity: [BundleIntegrity.Problem],
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.runner = runner
        self.ledger = ledger
        self.build = build
        self.highestBuild = highestBuild
        self.now = now
        if !selfIntegrity.isEmpty { startupEvents.append(.selfIntegrityFailed(selfIntegrity.map(\.reason).joined(separator: " "))) }
        if let highestBuild, build < highestBuild { startupEvents.append(.rolledBack(running: build, highest: highestBuild)) }
    }

    /// 실행 중인 빌드가 본 적 있는 가장 높은 빌드보다 낮다(D20). 그러면 모든 메서드가 오류를 돌려준다.
    public nonisolated var isRolledBack: Bool {
        highestBuild.map { build < $0 } ?? false
    }

    /// init 상수만 읽어 동기로 부를 수 있다 — `markUserQuit` 어댑터가 응답 전에 동기로 확인한다.
    public nonisolated func ensureNotRolledBack() throws(HaetaeXPCError) {
        if isRolledBack { throw .rolledBack }
    }

    /// 디스크의 자기 번들 빌드가 실행 중인 빌드보다 높으면, 진행 중인 작업이 끝난 뒤 종료해야 한다(D20, Q30). 번들은 `main`이 읽는다.
    public nonisolated static func isNewerBuild(onDisk diskBuild: Int?, running: Int) -> Bool {
        (diskBuild ?? .min) > running
    }

    /// 검사 결과를 응답 한도에 맞춰 인코딩해 돌려준다.
    public func collect(callerUID uid: uid_t) async throws(HaetaeXPCError) -> Data {
        await flushQueuedEvents()
        try ensureNotRolledBack()
        if let running = inFlight[uid] { return try await running.value.get() }
        let at = now()
        // 끝난 결과를 다시 보내지 않는다 — 이미 ack한 건을 또 알리게 된다.
        if let last = lastStarted[uid], at - last < Self.collectInterval { throw .rateLimited }
        lastStarted[uid] = at
        // 실행이 끝나는 바로 그때 지운다 — 부른 쪽이 깨어나기를 기다리면 그 틈에 온 요청이 끝난 결과를 받는다.
        let task = Task {
            let result = await self.produce(uid)
            self.inFlight[uid] = nil
            return result
        }
        inFlight[uid] = task
        return try await task.value.get()
    }

    /// pending에 있던 지문만 알림 완료로 바꾸고(D24 — 아무 지문이나 ack해 앞으로의 탐지를 숨기지 못하게), 남은 pending이 없는
    /// 검사의 기준값을 확정한다. 앱은 `collect`마다(탐지 0건이면 빈 목록으로) ack한다 — 검사 공백 표시도 이때 지워진다(Q67).
    public func ack(_ fingerprintsJSON: Data, callerUID uid: uid_t) async throws(HaetaeXPCError) {
        await flushQueuedEvents()
        try ensureNotRolledBack()
        guard let fingerprints = try? HaetaeXPC.decodeAck(fingerprintsJSON) else { throw .invalidInput }
        await ledger.acknowledge(fingerprints, uid: uid)
        do {
            try await runner.confirmAfterAck(uid: uid)
        } catch {
            // ack는 이미 원장에 들어갔다. 확정하지 못한 기준값은 다음 실행이 pending이 없을 때 확정한다.
            ChecksLog.ledger.error("ack 뒤 기준값 확정 실패 (uid \(uid, privacy: .public))")
        }
    }

    /// 메뉴 "종료"에서만 온다(D28). 되돌리기 확인은 어댑터가 응답 전에 동기로 한다.
    public func userQuit(callerUID uid: uid_t) async {
        await flushQueuedEvents()
        guard !isRolledBack else { return }
        await ledger.record([.userQuit], uid: uid)
    }

    /// 연결이 끊길 때마다 부른다. 유효한 호출이 있던 연결이 `markUserQuit` 없이 끊기면 비정상 종료로 세고 다음 `collect`에 검사
    /// 공백을 싣는다(Q31). 유효한 호출 없이 끊긴 연결(서명 요구사항에 걸림)도 센다. 둘 다 누구나 되풀이할 수 있어 묶어 적는다(Q66).
    /// 디스크에 새 빌드가 있을 때 끊긴 연결은 데몬이 넘기지 않는다(`DaemonLifecycleState.connectionClosedDuringUpdate`) — 업데이트
    /// 직후 새 앱이 옛 데몬에 붙었다 끊거나 서명 요구사항으로 거부한 것이라 비정상 종료도 공격도 아니다. 잃는 것은 업데이트 뒤 옛
    /// 데몬이 내려가기 전 1초 남짓 사이의 진짜 비정상 종료뿐이다.
    public func connectionClosed(callerUID uid: uid_t, userQuit: Bool, hadValidCall: Bool) async {
        guard !isRolledBack else { return await flushQueuedEvents() }
        if !hadValidCall {
            invalidConnections.count += 1
        } else if !userQuit {
            abnormalTerminations[uid, default: EventBatch()].count += 1
            await ledger.markScanGap(uid: uid)
        }
        await flushQueuedEvents()
    }

    /// 유휴 종료 직전에 부른다. 묶어 두고 아직 적지 않은 건수를 간격과 상관없이 적는다 — 몰아서 시도한 뒤 멈추면 사라지지 않게.
    public func prepareForExit() async {
        await flushQueuedEvents(force: true)
    }

    /// 응답 한도에 맞춘다(WO-12 1번).
    /// - `resolved`는 다 싣는다 — 원장에서 이미 지웠고, 알림 완료 상한(2,000) × 66바이트라 한도의 4%를 넘지 않는다.
    /// - 요약(`notified`)을 findings보다 먼저 싣는다 — 탐지를 쏟아내 패널 다시 만들기(Q53)를 막지 못하게. 최대 약 2.3MB(증거 해시 포함)라 늘 들어가고,
    ///   그래도 넘치면 통째로 뺀다(일부만 보내면 앱이 빠진 것을 사라진 것으로 볼 수 있다). 이번 findings에 있는 지문은 뺀다 — 실행
    ///   도중 온 ack로 둘 다에 들어가면 앱이 두 번 알린다.
    /// - findings는 `Finding.deliveryOrder`(수준 → 먼저 잡힌 것)로 개수(`maxFindingsPerReply`)와 바이트 안에서 싣는다. 못 실은
    ///   건수는 `droppedFindings`에 더하고(검사별로 자른 수를 덮지 않는다), 못 실은 건은 원장에 pending으로 남아 다음 응답에 간다.
    static func fit(_ result: CollectResult, notified: [NotifiedSummary], limit: Int = HaetaeLimits.maxReplyBytes) throws -> CollectResult {
        var reply = result
        reply.findings = []
        reply.notified = nil
        let budget = limit - replySlack
        var used = try JSONWire.encode(reply).count
        let current = Set(result.findings.map(\.fingerprint))
        let summaries = notified.filter { !current.contains($0.fingerprint) }
        // `,"notified":` 키와 괄호 몫을 더한다.
        let summaryBytes = try JSONWire.encode(summaries).count + 16
        if used + summaryBytes <= budget {
            reply.notified = summaries
            used += summaryBytes
        }
        for finding in result.findings.sorted(by: Finding.deliveryOrder).prefix(HaetaeLimits.maxFindingsPerReply) {
            // 배열 안의 한 건 = 그 건을 따로 인코딩한 크기 + 쉼표.
            let size = try JSONWire.encode(finding).count + 1
            guard used + size <= budget else { break }
            used += size
            reply.findings.append(finding)
        }
        let dropped = (result.droppedFindings ?? 0) + result.findings.count - reply.findings.count
        reply.droppedFindings = dropped > 0 ? dropped : nil
        return reply
    }

    private func produce(_ uid: uid_t) async -> Result<Data, HaetaeXPCError> {
        await purgeIfDue()
        // 실행 전에 잰다 — 공백은 앱이 마지막으로 결과를 받은 때부터 이번 `collect`까지다. 지우는 것은 ack다(Q67).
        let scanGap = await ledger.scanGap(uid: uid)
        let result = await runner.runAll(callerUID: uid)
        let notified = await ledger.unresolvedNotified(uid: uid).map(NotifiedSummary.init)
        do {
            var reply = try Self.fit(result, notified: notified)
            reply.scanGap = scanGap
            return .success(try reply.encodeValidated())
        } catch {
            ChecksLog.checks.error("collect 응답 생성 실패 (uid \(uid, privacy: .public))")
            return .failure(.internalError)
        }
    }

    private func purgeIfDue() async {
        let at = now()
        if let lastPurge, at - lastPurge < Self.purgeInterval { return }
        // 기다리기 전에 적는다 — 다른 사용자의 `collect`가 같은 정리를 또 줄 세우지 않게.
        lastPurge = at
        do {
            try await runner.purge(olderThan: Self.retention)
        } catch {
            // 실패한 정리는 다음 날 다시 한다. 남은 pending 기준값은 다음 실행이 같은 항목을 다시 잡아 덮는다.
            ChecksLog.ledger.error("오래된 기록 정리 실패")
        }
    }

    /// 시작할 때 생긴 일과, 간격이 지난 묶음(또는 `force`면 전부)을 원장에 적는다. 적을 것을 먼저 비운다 — 기다리는 동안 다시
    /// 불려도 두 번 적지 않게.
    private func flushQueuedEvents(force: Bool = false) async {
        let at = now()
        var system = startupEvents
        startupEvents = []
        if let count = invalidConnections.take(at: at, interval: Self.batchInterval, force: force) {
            system.append(.verificationFailedConnection(count: count))
        }
        var perUser: [(uid_t, Int)] = []
        for uid in abnormalTerminations.keys {
            if let count = abnormalTerminations[uid]?.take(at: at, interval: Self.batchInterval, force: force) { perUser.append((uid, count)) }
        }
        await ledger.record(system, uid: nil)
        for (uid, count) in perUser { await ledger.record([.abnormalTermination(count: count)], uid: uid) }
    }
}

/// 묶어 적는 사건 하나의 상태(Q66): 첫 건은 바로, 그 뒤는 간격이 지난 다음 기회에 그동안의 건수를 합쳐 적는다.
struct EventBatch {
    var count = 0
    var lastRecorded: ContinuousClock.Instant?

    /// 적을 때가 됐으면 건수를 꺼내고 비운다.
    mutating func take(at: ContinuousClock.Instant, interval: Duration, force: Bool) -> Int? {
        guard count > 0, force || lastRecorded.map({ at - $0 >= interval }) ?? true else { return nil }
        defer {
            count = 0
            lastRecorded = at
        }
        return count
    }
}
