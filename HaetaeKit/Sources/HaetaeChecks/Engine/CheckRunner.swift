import Foundation
import HaetaeShared
import os

enum CheckFailure: Error {
    case timeout
    /// 검사가 지문 형식이 아닌 값을 냈다(구현 결함). 그대로 보내면 앱이 응답 전체를 거부한다.
    case invalidFingerprint
}

/// 검사를 차례로 돌리고 결과를 원장과 기준값에 반영한다(D17·D24). 동시 실행은 하나다(D26).
public actor CheckRunner {
    /// 검사 실패, 호출 사용자 조회 실패, 기준값 손상을 알리는 Finding의 checkID.
    static let failureCheckID = "haetae.check-failure"
    /// 데몬 저장소 문제(pending 상한 초과, 디스크에 쓰지 못함)를 알리는 Finding의 checkID.
    static let storageCheckID = "haetae.storage"
    static let userScope = "user-scope"
    /// 최근 `FindingLedger.failureWindow`(5)번 중 이만큼 실패하면 높음으로 올린다 — 특정 검사를 조용히 무력화하는 것을
    /// 드러낸다(T12, Q58).
    static let escalateAfter = 3
    /// pending이 넘쳐도 버리지 않는 checkID. 넘침·실패를 알리는 Finding이라 가장 새로운 높음이 되기 쉬워, 지키지 않으면
    /// 자기가 먼저 버려진다. 개수는 검사 수에 묶여 있어 이것으로 pending을 채울 수는 없다.
    static let protectedCheckIDs: Set<String> = [failureCheckID, storageCheckID]
    /// 호출 사용자 조회의 상한. 보통 0.1초 안에 끝난다 — 홈이 멈춘 볼륨에 있어도 검사 시간을 다 쓰지 않게.
    static let userLookupTimeout: Duration = .seconds(5)
    /// 검사 하나가 낸 Finding을 다듬는(비밀 가리기) 데 쓸 수 있는 시간. 넘으면 남은 것은 다음 실행으로 미룬다 — 공격자가 고른
    /// 내용으로 가리기를 붙잡아 그 검사와 뒤의 검사를 타임아웃으로 떨어뜨리지 못하게. 실제로는 남은 시간을 남은 검사와 나눈 값과 작은 쪽.
    public static let maskBudget: Duration = .seconds(2)

    private let checks: [any SecurityCheck]
    /// 원장 기록이 지금도 쓰일 수 있는 checkID — 등록된 검사와 내부 상태. 이 밖의 기록은 실행마다 치운다(WO-56).
    private let knownCheckIDs: Set<String>
    private let baseline: BaselineStore
    private let ledger: FindingLedger
    private let patterns: PatternStore
    private let reader: SafeFileReader
    private let runner: CommandRunner
    private let parser: IsolatedParser
    private let daemonBuild: Int
    private let maxRunDuration: Duration
    private let maskBudget: Duration
    private let now: @Sendable () -> Date
    /// 줄에 있거나 도는 실행(사용자마다 하나).
    private var queued: [uid_t: Task<CollectResult, Never>] = [:]
    /// 마지막으로 줄에 세운 일(실행이나 `purge`). 다음 일은 이것이 끝난 뒤에 돈다.
    private var last: Task<Void, Never>?
    /// 줄에 세운 일 수. ack 뒤 확정이 기다리는 동안 실행이나 `purge`가 끼었는지 알아보는 데 쓴다.
    private var scheduled = 0
    /// `purge`가 도는 중이다. 그동안 ack 확정을 막는다.
    private var purging = false
    /// 사용자·검사마다 지난 실행에서 다음으로 미룬 지문(메모리, 앞 8바이트만 — `rememberKey`). 다음 실행은 같은 수준 안에서 이것부터
    /// 다듬는다 — 실행마다 새로 만든 탐지를 쏟아내 진짜 탐지를 계속 미루지 못하게(보안 4차 재리뷰 실측). 데몬이 다시 뜨면 잊는다 —
    /// 그때는 섞기와 수준마다 한 건 보장에 맡긴다.
    private var deferred: [String: Set<UInt64>] = [:]
    /// 검사마다 기억하는 미룬 지문 수. 적으면 아주 큰 쏟아내기(5,000건)에서 진짜 탐지가 기억에 못 들어 여러 번 늦는다(보안 5차
    /// 재리뷰 실측). 지문 하나에 8바이트라 검사당 약 1MB.
    static let maxRemembered = 100_000

    /// - Parameters:
    ///   - runner: 데몬 전체에서 하나만 만든 것을 넘긴다(직렬화가 인스턴스 단위다).
    ///   - maxRunDuration, maskBudget, now: 테스트에서 주입한다(바쁜 기계에서 다음으로 미루는 일 없이 개수를 보려면 예산을 늘린다).
    public init(
        checks: [any SecurityCheck] = CheckRegistry.all, baseline: BaselineStore, ledger: FindingLedger, patterns: PatternStore = PatternStore(),
        reader: SafeFileReader = SafeFileReader(), runner: CommandRunner, parser: IsolatedParser, daemonBuild: Int,
        maxRunDuration: Duration = HaetaeLimits.maxRunDuration, maskBudget: Duration = CheckRunner.maskBudget, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        // 검사 id가 틀리면 응답 전체가 `validate()`에서 떨어져 모든 탐지가 막힌다 — 검사를 더한 사람이 바로 알게 여기서 멈춘다.
        let ids = checks.map(\.id)
        precondition(ids.allSatisfy(Finding.isCheckID), "검사 id는 소문자·숫자·`.`·`-`만 쓴다")
        precondition(Set(ids).count == ids.count, "검사 id가 겹친다")
        precondition(Set(ids).isDisjoint(with: Self.protectedCheckIDs.union([Self.userScope])), "예약된 id를 검사 id로 쓸 수 없다")
        self.checks = checks
        knownCheckIDs = Set(ids).union(Self.protectedCheckIDs)
        self.baseline = baseline
        self.ledger = ledger
        self.patterns = patterns
        self.reader = reader
        self.runner = runner
        self.parser = parser
        self.daemonBuild = daemonBuild
        self.maxRunDuration = maxRunDuration
        self.maskBudget = maskBudget
        self.now = now
    }

    /// 같은 사용자의 요청은 줄에 있거나 도는 그 사용자 실행의 결과를 같이 받는다. 다른 사용자는 온 순서대로, 앞 실행이 끝난 뒤
    /// 자기 범위로 돈다 — 합치면 다른 사용자의 홈·TCC 결과를 받게 되고(D29), 순서를 지키지 않으면 한 사용자가 계속 요청해
    /// 다른 사용자의 실행을 끝없이 밀어낼 수 있다.
    public func runAll(callerUID: uid_t) async -> CollectResult {
        if let mine = queued[callerUID] { return await mine.value }
        let previous = last
        // 여러 호출이 한 결과를 기다려야 해서 호출한 쪽에 묶이지 않는 Task로 둔다.
        let task = Task {
            await previous?.value
            let result = await self.run(callerUID)
            self.queued[callerUID] = nil
            return result
        }
        queued[callerUID] = task
        last = Task { _ = await task.value }
        scheduled += 1
        return await task.value
    }

    /// 오래된 기록 지우기(R11 — 30일, WO-12가 부른다. `FindingLedger.purge`를 직접 부르지 않는다). pending을 지운 검사의 pending
    /// 기준값도 치운다 — 그 기준값에는 알리지 못한 항목이 들어 있어 뒤의 확정으로 정상으로 굳는다. 실행과 같은 줄에 서서 돈다 —
    /// 실행 도중 pending을 지우면 그 실행이 그 검사의 기준값을 확정한다. 도는 동안 ack 확정도 막는다(보안 4차 재리뷰 실측).
    /// 치우기가 실패해도 나머지는 계속하고 첫 오류를 마지막에 던진다(다음 실행이 같은 항목을 다시 잡아 pending 기준값을 덮는다).
    public func purge(olderThan age: TimeInterval) async throws {
        let previous = last
        let task = Task { () -> (any Error)? in
            await previous?.value
            return await self.runPurge(olderThan: age)
        }
        last = Task { _ = await task.value }
        scheduled += 1
        if let error = await task.value { throw error }
    }

    private func runPurge(olderThan age: TimeInterval) async -> (any Error)? {
        purging = true
        defer { purging = false }
        var firstError: (any Error)?
        for (uid, checkIDs) in await ledger.purge(olderThan: age) {
            for checkID in checkIDs {
                do {
                    try baseline.discardPending(checkID: checkID, uid: uid)
                } catch {
                    firstError = firstError ?? error
                }
            }
        }
        return firstError
    }

    /// ack 뒤 기준값 확정(D24, WO-12 2번). ack되지 않은 Finding이 남지 않은 검사의 pending 기준값을 확정한다.
    /// 그 사용자 실행이 줄에 있거나 도는 중이면(묻는 동안 끼어든 경우 포함) 건너뛴다 — 실행이 탐지를 버리고 그 검사의 pending
    /// 기준값을 치우기 전에 끼어들면, 한 번도 알리지 않은 항목이 든 기준값이 확정된다(보안 재리뷰 실측). 그 실행이 끝에 직접 판정한다.
    /// 한 검사의 확정이 실패해도 나머지는 계속 확정하고, 첫 오류를 마지막에 던진다.
    public func confirmAfterAck(uid: uid_t) async throws {
        // 묻기 전에도 본다 — 시작할 때 돌던 실행이 묻는 동안 끝나면 `scheduled`는 그대로라 그 실행 전의 낡은 목록으로 확정한다.
        guard queued[uid] == nil, !purging else { return }
        let before = scheduled
        let pending = await ledger.pendingCheckIDs(uid: uid)
        guard queued[uid] == nil, !purging, scheduled == before else { return }
        var firstError: (any Error)?
        for check in checks where check.needsBaseline && !pending.contains(check.id) {
            do {
                try baseline.confirmPending(checkID: check.id, uid: uid)
            } catch {
                firstError = firstError ?? error
            }
        }
        if let firstError { throw firstError }
    }

    private func run(_ uid: uid_t) async -> CollectResult {
        // 잠자기 동안은 세지 않는다 — 실행 도중 맥이 잠들면 깨어난 뒤 남은 검사가 모두 타임아웃 실패로 쌓인다.
        let clock = SuspendingClock()
        let started = clock.now
        let deadline = started + maxRunDuration
        // 파일·로그 시각은 넣지 않는다 — 범위 밖 시각 하나(`touch -t 1960…`)로 응답 전체가 거부된다.
        let observedAt = now()
        let pack = patterns.current
        // 검사 시간 안(`withTimeout`의 클로저)에서도 쓴다.
        let ledger = self.ledger

        var findings: [Finding] = []
        var failedChecks: [String] = []
        var succeeded: [(check: any SecurityCheck, newBaseline: Data?, firstRun: Bool)] = []
        /// 전부 본 검사. 이 검사의 Finding만 "안 보이면 해결"로 판정한다.
        var complete: Set<String> = []
        /// 이번에 아직 있는 것으로 볼 지문(검사가 낸 것 전부 — 상한에 잘린 것, 이미 알린 것 포함). 해결 판정은 이것으로 한다 —
        /// 잘린 목록으로 하면 아직 있는 것이 해결로 간다.
        var reported: Set<String> = []
        /// 상한에 걸려 원장에 다 넣지 못한 검사. 기준값과 `lastSuccess`를 그대로 둬 다음 실행이 같은 것을 다시 낸다.
        var capped: Set<String> = []
        /// 다 보지 못한 검사(호출 사용자를 몰라 사용자 부분을 건너뛰었거나 `partial`). `lastSuccess`를 그대로 둬 못 본 구간을
        /// 다음에 다시 본다(Q57 1번).
        var unseen: Set<String> = []
        /// 기준값을 그대로 둘 검사: 호출 사용자를 모르거나(첫 실행 포함 — 사용자 부분이 빠진 기준값이 굳지 않게), 첫 실행이 아닌
        /// `partial`. 첫 실행의 `partial`은 저장·확정한다(Q62 1번) — 건너뛰면 깨진 파일 하나로 첫 실행이 끝없이 이어져 그 사이
        /// 설치한 항목이 나중에 정상으로 학습된다. 못 본 파일의 항목은 기준값에 없으니 나중에 읽히면 "새로 생김"으로 잡힌다.
        var keepBaseline: Set<String> = []
        /// 이번에 `partial`이 아니었거나 미루지 않은 검사의 기록 키(`partial:<검사 ID>`·`cap:<검사 ID>`, 성공으로 남긴다).
        var okKeys: [String] = []
        var recovered: [String] = []

        // 높음으로 오른 뒤에도 실패가 이어지는 동안은 중간 Finding을 해결로 보내지 않는다 — 실패 중인데 "해결됨"이 뜬다.
        func addFailure(_ subject: String, title: String, reason: String, failures: Int) {
            findings.append(Self.failure(subject, title: title, reason: reason, failures: failures, at: observedAt))
            if failures >= Self.escalateAfter { reported.insert(Self.failureFingerprint(subject, level: .medium)) }
        }

        // 멈춘 홈 볼륨에서는 돌아오지 않을 수 있어 상한을 건다(취소되면 전용 스레드를 두고 돌아온다).
        let runner = self.runner
        let user = try? await withTimeout(min(Self.userLookupTimeout, deadline - clock.now)) {
            try await UserDirectory.user(uid: uid, runner: runner)
        }
        if user == nil {
            let failures = await ledger.noteFailure(Self.userScope, uid: uid)
            addFailure(Self.userScope, title: "사용자 범위 검사를 건너뜀", reason: "호출 사용자 계정을 확인하지 못했습니다.", failures: failures)
        } else {
            recovered.append(Self.userScope)
        }

        for (index, check) in checks.enumerated() {
            var stored: Data?
            if check.needsBaseline {
                do {
                    stored = try baseline.load(checkID: check.id, uid: uid, version: check.baselineVersion)
                } catch {
                    // 깨진 기준값을 조용히 다시 학습하면 그때 있던 악성 항목이 정상으로 굳는다(T13). 실패로 드러내고,
                    // 이어지면 옆으로 옮긴 뒤 높음으로 알리고 다시 학습한다 — 사람이 root 파일을 지우지 않아도 회복하게.
                    let failures = await ledger.noteFailure(check.id, uid: uid)
                    guard failures >= Self.escalateAfter, (try? baseline.quarantine(checkID: check.id, uid: uid)) != nil else {
                        addFailure(check.id, title: "검사 실패: \(check.id)", reason: "기준값을 읽지 못했습니다.", failures: failures)
                        failedChecks.append(check.id)
                        continue
                    }
                    findings.append(Self.status(
                        Self.failureCheckID, subject: "baseline:\(check.id)", title: "기준값 손상: \(check.id)",
                        evidence: "최근 \(FindingLedger.failureWindow)번 중 \(failures)번 기준값을 읽지 못해 옆으로 옮기고 다시 학습합니다. 그동안 생긴 변화는 새로 생긴 것으로 잡히지 않습니다.", at: observedAt
                    ))
                }
            }

            let firstRun = check.needsBaseline && stored == nil
            do {
                // 전체 상한을 넘겼으면 남은 검사는 돌리지 않고 타임아웃 실패로 올린다.
                let budget = min(check.timeout, deadline - clock.now)
                guard budget > .zero else { throw CheckFailure.timeout }
                let ctx = CheckContext(
                    baseline: stored, isFirstRun: firstRun, patterns: pack.checks[check.id] ?? .object([:]),
                    user: user, reader: reader, runner: runner, parser: parser, since: await ledger.lastSuccess(checkID: check.id, uid: uid)
                )
                // 가리기 시간은 남은 시간을 남은 검사와 나눈 몫의 절반까지 — 검사가 늘어도 앞 검사의 가리기가 뒤 검사의 시간을 먹지
                // 않고, 검사 자체와 실행 끝의 저장에도 시간이 남게(나누기만 하면 검사 14개 실측에서 25초 상한을 다 썼다).
                let maskBudget = min(self.maskBudget, (deadline - clock.now) / (2 * (checks.count - index)))
                let deferredKey = "\(uid)/\(check.id)"
                let prior = deferred[deferredKey] ?? []
                // 다듬기(비밀 가리기)도 시간 안에 넣는다 — 검사가 낸 내용에 따라 오래 걸릴 수 있다.
                let (result, prepared) = try await withTimeout(budget) {
                    let result = try await check.run(ctx)
                    // 이미 알린 것은 원장이 어차피 거른다 — 검사별 상한 앞에서 빼지 않으면 그 자리를 차지해 뒤의 새 탐지가 영영 막힌다.
                    // 검사가 끝난 뒤에 읽는다 — 검사가 도는 동안 온 ack를 빠뜨리면 가짜 "상한 초과"가 난다.
                    let notified = await ledger.notifiedFingerprints(uid: uid)
                    return (result, try Self.prepare(result.findings, checkID: check.id, skipping: notified, first: prior, maskBudget: maskBudget, at: observedAt))
                }
                findings += prepared.kept
                reported.formUnion(result.findings.lazy.map(\.fingerprint))
                deferred[deferredKey] = prepared.deferred.isEmpty ? nil : Set(prepared.deferred.prefix(Self.maxRemembered).map(Self.rememberKey))
                let capKey = "cap:\(check.id)"
                if prepared.deferred.isEmpty {
                    okKeys.append(capKey)
                } else {
                    capped.insert(check.id)
                    // 개수 상한에 걸렸으면 쏟아내기일 수 있어 높음. 시간만 모자랐으면 바쁜 맥에서도 생기는 일이라 낮음이고(다음 실행에
                    // 간다), 최근 5번 중 3번이면 중간 — 이어지면 기준값·`since`가 조용히 묶인다(설계 5차 재리뷰, Q62와 같은 규칙).
                    var level = RiskLevel.high
                    var reason = "한 번에 낸 탐지가 너무 많아"
                    if !prepared.overCount {
                        let delays = await ledger.noteFailure(capKey, uid: uid)
                        level = delays >= Self.escalateAfter ? .medium : .low
                        reason = "최근 \(FindingLedger.failureWindow)번 중 \(delays)번 다듬는 데 시간이 모자라"
                        if level == .medium { reported.insert(Fingerprint.make(checkID: Self.failureCheckID, subject: capKey, contentHash: RiskLevel.low.rawValue)) }
                    }
                    findings.append(Self.status(
                        Self.failureCheckID, subject: capKey, title: "탐지 일부를 다음으로 미룸: \(check.id)",
                        evidence: "\(reason) \(prepared.deferred.count)건을 다음으로 미뤘습니다. 다음 검사에서 먼저 보냅니다." + (prepared.overCount ? " 탐지를 쏟아내 다른 탐지를 가리려는 시도일 수 있습니다." : ""),
                        level: level, contentHash: level.rawValue, at: observedAt
                    ))
                }
                succeeded.append((check, result.newBaseline, firstRun))
                let partialKey = "partial:\(check.id)"
                if result.partial {
                    // 조용히 건너뛰기만 하면 파일 하나로 그 검사를 멈출 수 있다 — 낮음으로 드러내고(Q57 1번), 최근 5번 중 3번이면
                    // 중간으로 올린다(Q62 1번 — 낮음은 위험으로 치지 않아 계속되면 사실상 조용하다). 수준을 지문에 넣어 오르면 다시 알린다.
                    let partials = await ledger.noteFailure(partialKey, uid: uid)
                    let level: RiskLevel = partials >= Self.escalateAfter ? .medium : .low
                    findings.append(Self.status(
                        Self.failureCheckID, subject: partialKey, title: "일부를 보지 못함: \(check.id)",
                        evidence: "파일 일부를 읽거나 해석하지 못해 이번에는 그 부분을 보지 못했습니다. 최근 \(FindingLedger.failureWindow)번 중 \(partials)번이며, 다음 검사에서 다시 봅니다.",
                        level: level, contentHash: level.rawValue, at: observedAt
                    ))
                    // 중간으로 오른 뒤에도 이어지는 동안 낮음 Finding을 해결로 보내지 않는다.
                    if level == .medium { reported.insert(Fingerprint.make(checkID: Self.failureCheckID, subject: partialKey, contentHash: RiskLevel.low.rawValue)) }
                } else {
                    okKeys.append(partialKey)
                }
                if user == nil || (result.partial && !firstRun) { keepBaseline.insert(check.id) }
                if user == nil || result.partial {
                    unseen.insert(check.id)
                } else {
                    complete.insert(check.id)
                }
            } catch {
                let failures = await ledger.noteFailure(check.id, uid: uid)
                let reason = if case CheckFailure.timeout = error { "시간 안에 끝나지 않았습니다." } else { Self.describe(error) }
                addFailure(check.id, title: "검사 실패: \(check.id)", reason: reason, failures: failures)
                failedChecks.append(check.id)
                ChecksLog.checks.error("검사 실패 \(check.id, privacy: .public) (최근 \(FindingLedger.failureWindow, privacy: .public)번 중 \(failures, privacy: .public)번)")
            }
        }
        // 실패마다 바로 저장하는 `noteFailure`는 모으지 않는다 — 모아서 저장하면 실행 도중 데몬이 내려갈 때(앱을 죽이면 5초 뒤)
        // 횟수가 오르지 않아 높음을 피할 수 있다(T12).
        await ledger.noteSuccesses(succeeded.map(\.check.id) + recovered + okKeys, uid: uid)

        // 두 검사가 같은 지문을 내면(검사 구현 결함) 원장이 뒤의 것으로 덮어 수준이 내려갈 수 있다 — 높은 것 하나만 남긴다.
        findings = Array(Dictionary(findings.map { ($0.fingerprint, $0) }, uniquingKeysWith: { $0.ruleLevel.rank >= $1.ruleLevel.rank ? $0 : $1 }).values)

        // 지금 돌리지 않는 검사의 기록을 먼저 치운다 — pending은 아래 `filterNew`가 다시 내보내지 않게, 알림 완료 건은 해결로(WO-56).
        let forgotten = await ledger.forgetChecks(notIn: knownCheckIDs, uid: uid)
        // 버린 pending의 기준값도 치운다 — 같은 id의 검사가 다시 들어와 첫 실행이 실패하면, 알리지 못한 항목이 든 옛 pending
        // 기준값이 ack 뒤에 확정된다(두 리뷰 L, `purge`와 같은 이유).
        for checkID in forgotten.droppedChecks { try? baseline.discardPending(checkID: checkID, uid: uid) }

        // 아래 순서를 바꾸지 않는다(WO-10 리뷰).
        // 응답에 바로 붙이지 않고 원장을 거친다 — 그래야 ack와 해결 판정이 된다. 상태 Finding도 같다.
        var outgoing = await ledger.filterNew(findings, uid: uid, protecting: Self.protectedCheckIDs)
        var droppedChecks = outgoing.droppedChecks
        var storage: [Finding] = []
        if outgoing.dropped > 0 {
            storage.append(Self.status(
                Self.storageCheckID, subject: "pending-overflow", title: "탐지 기록 상한 초과",
                evidence: "확인하지 않은 탐지가 너무 많아 수준이 낮은 \(outgoing.dropped)건 이상을 버렸습니다. 탐지를 쏟아내 다른 탐지를 밀어내려는 시도일 수 있습니다.", at: observedAt
            ))
            outgoing = await ledger.filterNew(storage, uid: uid, protecting: Self.protectedCheckIDs)
            droppedChecks.formUnion(outgoing.droppedChecks)
        }

        // 기준값 저장은 반드시 `filterNew` 뒤다 — 앞서면 그 사이의 ack로, 아직 원장에 없는 탐지가 든 기준값이 확정된다.
        var storageFailed = false
        // 버린 탐지가 있는 검사의 pending 기준값은 치운다 — 한 번도 알리지 못한 항목이 들어 있어, 뒤에 ack로 확정되면(WO-12)
        // 정상으로 굳는다. 다음 실행이 옛 확정 기준값으로 같은 것을 다시 잡는다.
        for checkID in droppedChecks {
            do {
                try baseline.discardPending(checkID: checkID, uid: uid)
            } catch {
                storageFailed = true
            }
        }
        let hold = capped.union(droppedChecks)
        for (check, newBaseline, firstRun) in succeeded where check.needsBaseline && !keepBaseline.contains(check.id) {
            // 상한에 걸렸거나 pending에서 버린 탐지가 있는 검사는 기준값을 그대로 둔다 — 원장에 없는 항목이 정상으로 굳는다.
            // 첫 실행은 예외다: 그때 탐지는 기준값과 무관한 규칙이 낸 것이라 다음 실행에도 다시 나온다.
            guard firstRun || !hold.contains(check.id) else { continue }
            do {
                if let newBaseline {
                    try baseline.savePending(newBaseline, checkID: check.id, uid: uid, version: check.baselineVersion)
                }
                // 첫 실행은 ack를 기다리지 않고 확정한다 — "새로 생김"을 보지 않아 ack로 지킬 탐지가 없고, 기다리면 확정될 때까지
                // 매번 첫 실행이 되어 그 사이 설치된 항목이 기준값에 정상으로 들어간다(T13).
                var confirm = firstRun
                if !confirm {
                    confirm = await !ledger.hasPending(checkID: check.id, uid: uid)
                }
                if confirm {
                    try baseline.confirmPending(checkID: check.id, uid: uid)
                }
            } catch {
                storageFailed = true
            }
        }
        // 그 실행의 Finding이 원장에 들어간 뒤에 갱신한다 — 먼저 하면 도중에 꺼졌을 때 그 구간을 다시 보지 못한다.
        // 원장에 다 넣지 못했거나 다 보지 못한 검사는 갱신하지 않아 다음 실행이 같은 구간을 다시 본다.
        await ledger.setLastSuccess(observedAt, checkIDs: succeeded.map(\.check.id).filter { !hold.contains($0) && !unseen.contains($0) }, uid: uid)

        // 회복된 검사의 실패 Finding도 해결로 가게 실패 checkID를 함께 넘긴다.
        var resolved = forgotten.resolved + (await ledger.resolved(
            current: reported.union(findings.map(\.fingerprint)), succeededChecks: complete.union([Self.failureCheckID]), uid: uid
        ))

        // 이번 실행의 쓰기가 모두 끝난 뒤에 꺼낸다. 저장소 Finding의 해결은 따로 판정한다 —
        // 위에서 같이 하면 계속 실패하는 동안 실행마다 "해결"과 "새 탐지"가 번갈아 나온다.
        let persistence = await ledger.takePersistenceFailure()
        if storageFailed || persistence != nil {
            let finding = Self.status(
                Self.storageCheckID, subject: "persistence", title: "탐지 기록을 저장하지 못함",
                evidence: "데몬 저장 폴더에 쓰지 못했습니다(\(persistence.map { "\($0)" } ?? "기준값")). 데몬이 다시 뜨면 이번 탐지를 잊을 수 있습니다.", at: observedAt
            )
            storage.append(finding)
            outgoing = await ledger.filterNew([finding], uid: uid, protecting: Self.protectedCheckIDs)
            // shortcut: 여기서 버린 검사는 pending 기준값만 치우고 `lastSuccess`는 이미 갱신됐다(저장 실패와 pending 가득 참이 겹칠 때만),
            // 로그 검사(WO-17)가 들어오면 이 순서를 다시 본다.
            for checkID in outgoing.droppedChecks { try? baseline.discardPending(checkID: checkID, uid: uid) }
        }
        resolved += await ledger.resolved(current: Set(storage.map(\.fingerprint)), succeededChecks: [Self.storageCheckID], uid: uid)

        // 원장의 pending은 여러 실행에 걸쳐 쌓여 검사별 상한을 넘을 수 있다. 넘은 것은 pending에 남아 다음에 간다.
        let (kept, cut) = Self.capPerCheck(outgoing.findings)
        let result = CollectResult(
            findings: kept, resolved: resolved, failedChecks: failedChecks, patternVersion: pack.version, daemonBuild: daemonBuild,
            droppedFindings: cut > 0 ? cut : nil
        )
        let elapsed = clock.now - started
        ChecksLog.checks.notice(
            "검사 \(self.checks.count, privacy: .public)개 중 실패 \(failedChecks.count, privacy: .public)개, 보냄 \(kept.count, privacy: .public)건, \(elapsed.components.seconds, privacy: .public)초 (uid \(uid, privacy: .public))"
        )
        do {
            try result.validate()
            return result
        } catch {
            // 여기 오면 구현 결함이다. 보내면 앱이 통째로 거부하므로, 탐지는 pending에 둔 채 실패만 알린다.
            ChecksLog.checks.fault("검사 결과가 검증을 통과하지 못함")
            return CollectResult(findings: [], resolved: [], failedChecks: [Self.failureCheckID], patternVersion: pack.version, daemonBuild: daemonBuild)
        }
    }

    // MARK: - Finding 다듬기

    /// 검사가 낸 Finding을 보낼 수 있는 모양으로 만든다: 이미 알린 것 빼기, 같은 지문은 하나만, 검사별 개수 상한(수준 높은 것부터),
    /// `checkID`·`observedAt` 채우기, 글자 정리.
    /// 다듬기가 `maskBudget`을 넘으면 남은 것은 다음 실행으로 미룬다(개수 상한과 같은 길 — 기준값·`since`를 묶어 다음에 다시
    /// 나온다). evidence를 지우거나 줄이지 않는다 — 공격자가 느린 evidence를 섞어 다른 탐지의 증거를 지울 수 있었다.
    /// 시간이 넘어도 수준마다 한 건은 다듬는다 — 높음을 쏟아내 낮은 수준의 진짜 탐지를 계속 밀어내지 못하게(설계 4차 재리뷰 실측).
    /// - Parameter prior: 지난 실행에서 미룬 지문(`rememberKey`). 같은 수준 안에서 먼저 다듬는다.
    /// - Returns: 남긴 것, 다음으로 미룬 지문, 개수 상한을 넘었는지(시간과 상관없이 센다 — 시간이 먼저 끝나면 수천 건을 쏟아내도
    ///   "시간 모자람"(낮음)으로만 보였다, 보안 5차 재리뷰 실측).
    static func prepare(
        _ findings: [Finding], checkID: String, skipping notified: Set<String>, first prior: Set<UInt64> = [],
        maskBudget: Duration = CheckRunner.maskBudget, at observedAt: Date
    ) throws -> (kept: [Finding], deferred: [String], overCount: Bool) {
        let clock = SuspendingClock()
        let maskUntil = clock.now + maskBudget
        var seen = Set<String>()
        var kept: [Finding] = []
        var deferred: [String] = []
        var levelsDone = Set<RiskLevel>()
        // 수준 → 지난번에 미룬 것 → 섞은 순서(정렬은 순서를 지킨다). 낸 순서대로 자르면, 순서를 정할 수 있는 공격자가 진짜 탐지를
        // 늘 상한 뒤로 민다. 지난번에 미룬 것을 앞에 두면 실행마다 새로 만든 탐지를 쏟아내도 한 번만 늦는다.
        let ordered = findings.shuffled().map { ($0, prior.contains(rememberKey($0.fingerprint)) ? 1 : 0) }
            .sorted { ($0.0.ruleLevel.rank, $0.1) > ($1.0.ruleLevel.rank, $1.1) }
        for (var finding, _) in ordered {
            guard Finding.isFingerprint(finding.fingerprint) else { throw CheckFailure.invalidFingerprint }
            guard !notified.contains(finding.fingerprint), seen.insert(finding.fingerprint).inserted else { continue }
            guard kept.count < HaetaeLimits.maxFindingsPerCheck else {
                deferred.append(finding.fingerprint)
                continue
            }
            guard clock.now < maskUntil || !levelsDone.contains(finding.ruleLevel) else {
                deferred.append(finding.fingerprint)
                continue
            }
            levelsDone.insert(finding.ruleLevel)
            try Task.checkCancellation()
            finding.checkID = checkID
            finding.observedAt = observedAt
            finding.title = clean(finding.title, limit: HaetaeLimits.maxTitleChars, multiline: false)
            finding.evidence = clean(finding.evidence, limit: HaetaeLimits.maxEvidenceChars, multiline: true)
            kept.append(finding)
        }
        return (kept, deferred, kept.count + deferred.count > HaetaeLimits.maxFindingsPerCheck)
    }

    /// 미룬 지문을 기억할 때 쓰는 값(지문 앞 16자리 16진수 = 8바이트). 겹쳐도 그 지문을 먼저 다듬을 뿐이라 해가 없다.
    static func rememberKey(_ fingerprint: String) -> UInt64 {
        UInt64(fingerprint.prefix(16), radix: 16) ?? 0
    }

    /// 보이지 않거나 화면을 속이는 문자 치환(`Finding.displaySafe`) → 비밀 가리기 → 길이 상한. 길이는 Unicode scalar 수로 세고 꼬리까지 포함해 상한 이하다.
    static func clean(_ text: String, limit: Int, multiline: Bool) -> String {
        // 가리기 전에 대강 자른다 — 공격자가 고른 긴 내용이 정규식을 오래 붙잡지 못하게. 자른 끝의 덩어리는 버린다 —
        // 잘린 토큰은 가리기 규칙에 걸리지 않아 앞부분이 그대로 나간다(공백이 없으면 덩어리째 가리기 규칙에 맡긴다).
        // 미리 잘랐으면 길이와 상관없이 꼬리를 붙인다 — 붙이지 않으면 뒤를 잘라낸 악성 명령이 무해한 명령처럼 보인다.
        var source = text.unicodeScalars.prefix(limit * 4)
        let precut = !text.unicodeScalars.dropFirst(limit * 4).isEmpty
        if precut, let lastSpace = source.lastIndex(where: \.properties.isWhitespace) {
            source = source[..<lastSpace]
        }
        let masked = SecretMasker.mask(Finding.displaySafe(String(String.UnicodeScalarView(source)), multiline: multiline))
        let tail = "…(잘림)"
        guard precut || masked.unicodeScalars.count > limit else { return masked }
        return String(String.UnicodeScalarView(masked.unicodeScalars.prefix(limit - tail.unicodeScalars.count))) + tail
    }

    /// 검사별로 `Finding.deliveryOrder` 순서로 상한까지만 남긴다. 잘라낸 건수를 함께 돌려준다.
    static func capPerCheck(_ findings: [Finding]) -> (kept: [Finding], cut: Int) {
        var kept: [Finding] = []
        for group in Dictionary(grouping: findings, by: \.checkID).values {
            kept += group.sorted(by: Finding.deliveryOrder).prefix(HaetaeLimits.maxFindingsPerCheck)
        }
        return (kept, findings.count - kept.count)
    }

    /// evidence에 넣을 오류 설명. 도메인(Swift 오류면 형식 이름)과 코드만 넣는다 — 설명 문자열에는 경로·키가 들어갈 수 있고
    /// evidence는 앱과 LLM으로 간다. `type(of:)`는 작업 그룹을 지난 Foundation 오류를 `NSError`로만 보여 쓰지 않는다.
    private static func describe(_ error: any Error) -> String {
        let error = error as NSError
        return "오류: \(error.domain) (코드 \(error.code))"
    }

    /// 수준을 지문에 넣는다 — 높음으로 오르면 새 Finding이 되어 다시 알린다.
    private static func failure(_ subject: String, title: String, reason: String, failures: Int, at observedAt: Date) -> Finding {
        let level: RiskLevel = failures >= escalateAfter ? .high : .medium
        return status(
            failureCheckID, subject: subject, title: title, evidence: "\(reason) 최근 \(FindingLedger.failureWindow)번 중 \(failures)번 실패했습니다.",
            level: level, contentHash: level.rawValue, at: observedAt
        )
    }

    private static func failureFingerprint(_ subject: String, level: RiskLevel) -> String {
        Fingerprint.make(checkID: failureCheckID, subject: subject, contentHash: level.rawValue)
    }

    private static func status(
        _ checkID: String, subject: String, title: String, evidence: String, level: RiskLevel = .high, contentHash: String = "", at observedAt: Date
    ) -> Finding {
        Finding(
            checkID: checkID, title: clean(title, limit: HaetaeLimits.maxTitleChars, multiline: false),
            evidence: clean(evidence, limit: HaetaeLimits.maxEvidenceChars, multiline: true), ruleLevel: level,
            fingerprint: Fingerprint.make(checkID: checkID, subject: subject, contentHash: contentHash), observedAt: observedAt
        )
    }
}

extension Finding {
    /// 보낼 것을 자를 때의 순서(검사별 상한, 응답 한도): 수준이 높은 것 → 먼저 잡힌 것(`observedAt`은 원장이 처음 본 시각으로 지킨다)
    /// → 지문. pending을 버릴 때(Q52)와 같은 원칙이다 — 뒤에 쏟아낸 건이 먼저 잡힌 탐지를 계속 밀어내지 못하게.
    /// 사전 순서에 맡기면 실행마다 순서가 달라져 진짜 탐지가 여러 번 연달아 밀린다(WO-12 리뷰 실측).
    static func deliveryOrder(_ a: Finding, _ b: Finding) -> Bool {
        if a.ruleLevel != b.ruleLevel { return a.ruleLevel.rank > b.ruleLevel.rank }
        if a.observedAt != b.observedAt { return a.observedAt < b.observedAt }
        return a.fingerprint < b.fingerprint
    }
}

/// 시간 안에 끝나지 않으면 취소하고 `CheckFailure.timeout`을 던진다. 잠자기 동안은 세지 않는다(`CheckRunner.run`과 같은 시계).
/// 취소에 응하지 않는 작업은 끝날 때까지 기다린다 — 검사는 취소에 응하는 `runner`·`reader`·`parser`만 쓴다.
func withTimeout<T: Sendable>(_ timeout: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        defer { group.cancelAll() }
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: timeout, clock: .suspending)
            return nil
        }
        guard case let result?? = try await group.next() else { throw CheckFailure.timeout }
        return result
    }
}
