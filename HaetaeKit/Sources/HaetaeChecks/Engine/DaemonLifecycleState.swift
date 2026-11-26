/// 데몬이 언제 끝날지(D15·Q30·Q36). 상태와 판단만 두고 타이머·`exit`는 데몬 타깃(`ListenerDelegate`)이 한다 — `swift test`로
/// 지키게(Q23). 데몬은 이것을 잠금 하나 안에 둔다.
public struct DaemonLifecycleState: Sendable {
    /// 종료 확인을 걸 때 기다릴 종류.
    public enum Wait: Sendable, Equatable {
        /// 연결 0개·작업 0개(D15, 5초).
        case idle
        /// 디스크에 새 빌드 — 연결이 남아 있어도 작업이 0이면 끝낸다(Q30, 방금 보낸 응답이 나갈 틈만 둔다).
        case newBuild
    }

    /// 종료 확인 하나. 그 뒤에 건 확인이 있거나(지난 것은 무효) 연결이 들어왔으면 `shouldExit`가 false다.
    public struct Ticket: Sendable, Equatable {
        let exit: Int
        let idle: Int
    }

    public private(set) var connections = 0
    /// 진행 중인 작업(`collect`·`ack`·`markUserQuit` 기록, 연결 종료 기록) 수(Q36).
    public private(set) var inFlight = 0
    public private(set) var newBuildPending = false
    /// 연결이 들어올 때마다 올린다.
    private var idleGeneration = 0
    /// 작업이 모두 끝날 때마다 올린다(종료 확인을 걸지 않을 때도). 그 전에 건 확인은 모두 무효다 — 앞서 건 확인이 방금 끝난 응답의
    /// 여유 시간을 건너뛰지 못하게(묵은 유휴 확인이 새 빌드를 안 순간 다시 유효해지는 것 포함, 5차 확인 실측). 업데이트 중 끊김과
    /// `updating` 응답은 작업이 아니라 올리지 않는다 — 되풀이해 확인을 계속 미루지 못하게.
    private var exitGeneration = 0

    public init() {}

    public mutating func connectionOpened() {
        connections += 1
        idleGeneration &+= 1
    }

    /// 연결 종료 기록을 마친 뒤, 그 작업 안에서 부른다(먼저 줄이면 기록 전에 유휴 종료가 날 수 있다).
    public mutating func connectionClosed() {
        connections -= 1
    }

    public mutating func beginWork() {
        inFlight += 1
    }

    /// 디스크에 새 빌드가 있음을 알았다(`collect` 전, 연결이 끊길 때). 처음 알았고 작업이 없으면 `.newBuild`, 그 뒤로는 nil이다. 업데이트 중 끊김이나 `updating` 응답은 작업으로 세지 않는다 —
    /// 그때마다 확인을 다시 걸면(앞의 것이 무효) 연결이나 `collect`를 1초보다 자주 되풀이해 옛 데몬을 붙잡아 둘 수 있다(재리뷰 실측).
    public mutating func noticeNewBuild() -> Wait? {
        defer { newBuildPending = true }
        return !newBuildPending && inFlight == 0 ? .newBuild : nil
    }

    /// 디스크에 새 빌드가 있을 때 끊긴 연결. 적을 것도 보낼 응답도 없다.
    public mutating func connectionClosedDuringUpdate() -> Wait? {
        connections -= 1
        return noticeNewBuild()
    }

    /// 마지막 작업이 끝났을 때만 종료 확인을 건다. 연결 수 감소는(업데이트 중 끊긴 연결 말고는) 늘 작업 안이라 여기서만 걸면 된다 —
    /// 검사 도중 앱이 죽어도 검사가 끝난 뒤 이쪽이 건다.
    /// - Returns: 걸어야 할 확인의 종류. nil이면 걸지 않는다.
    public mutating func endWork() -> Wait? {
        inFlight -= 1
        guard inFlight == 0 else { return nil }
        exitGeneration &+= 1
        if newBuildPending { return .newBuild }
        return connections == 0 ? .idle : nil
    }

    public func armExitCheck() -> Ticket {
        Ticket(exit: exitGeneration, idle: idleGeneration)
    }

    /// 지연 뒤에 한 번, 묶어 둔 기록을 적은 뒤에 한 번 더 본다.
    public func shouldExit(_ ticket: Ticket) -> Bool {
        inFlight == 0 && ticket.exit == exitGeneration && (newBuildPending || (connections == 0 && ticket.idle == idleGeneration))
    }
}
