import HaetaeShared

/// 앱이 데몬에 다시 붙을지·다시 뜰지 정하는 규칙(WO-5 리뷰, WO-13 6-1). XPC 호출은 `DaemonClient`가 하고 판단만 여기 둔다 —
/// Release 동작은 유료 계정이 있어야 실측할 수 있어(P6) `swift test`로 지킨다.
public enum ReconnectPolicy {
    /// 첫 시도 뒤 다시 시도하기 전에 기다리는 시간. 옛 데몬이 꺼지고 새 데몬이 뜰 시간을 준다(D20).
    public static let retryDelays: [Duration] = [.seconds(5), .seconds(15), .seconds(30)]
    /// 이 빌드로 앱이 스스로 다시 뜨는 횟수의 상한 — 넘으면 끝없이 다시 뜨지 않게 멈춘다.
    public static let maxRelaunches = 3

    /// `collect` 한 번 시도한 결과.
    public enum Attempt: Sendable, Equatable {
        /// 응답을 받았다. Debug에서만 머리의 빌드를 넘긴다 — Release는 서명 요구사항이 같은 빌드만 통과시킨다.
        case reply(headerBuild: Int?)
        /// 옛 데몬이 곧 끝난다(D20).
        case updating
        /// 이 사용자의 검사가 막 시작됐다(20초 안 재요청).
        case rateLimited
        /// 그 밖의 데몬 오류(`HaetaeXPCError`) — 그대로 올린다.
        case daemonError
        /// 무효화·중단·타임아웃. `signature`면 서명 요구사항에 걸린 것으로 보인다.
        case noReply(signature: Bool)
    }

    public enum Step: Sendable, Equatable {
        case accept
        /// 디스크의 앱이나 데몬이 더 새 빌드다 — 앱이 다시 떠야 한다(D20).
        case relaunch
        /// Debug: 등록된 데몬(root 사본)이 이 앱보다 옛 빌드다. 다시 시도해도 같은 옛 파일이 뜨니, 사용자 종료로 알리고 연결을 놓은 뒤 끝낸다.
        case staleDaemon
        case retry(after: Duration, dropConnection: Bool)
        /// 받은 데몬 오류를 그대로 올린다.
        case rethrow
        case giveUp(verificationFailed: Bool)
    }

    /// `collect` 한 번(최대 4번 시도) 동안의 기억.
    public struct State: Sendable, Equatable {
        var attempts = 0
        var sawVerificationFailure = false
        var waitedForRateLimit = false

        public init() {}
    }

    /// 시도 전에 본다. Release에서는 빌드가 다르면 서명 요구사항 때문에 응답이 오지 않으니, 응답 대신 디스크의 자기 빌드를 본다.
    public static func shouldRelaunch(diskBuild: Int, running: Int) -> Bool {
        diskBuild > running
    }

    public static func next(after attempt: Attempt, running: Int, state: inout State) -> Step {
        state.attempts += 1
        switch attempt {
        case .reply(let headerBuild):
            guard let headerBuild else { return .accept }
            if headerBuild > running { return .relaunch }
            return headerBuild < running ? .staleDaemon : .accept
        case .daemonError:
            return .rethrow
        case .rateLimited:
            guard !state.waitedForRateLimit else { return .rethrow }
            state.waitedForRateLimit = true
            return retry(state, after: HaetaeLimits.minCollectInterval, dropConnection: false)
        case .updating:
            // 연결을 쥐고 있으면 옛 데몬이 끝나지 못한다.
            return retry(state, after: nil, dropConnection: true)
        case .noReply(let signature):
            if signature { state.sawVerificationFailure = true }
            return retry(state, after: nil, dropConnection: false)
        }
    }

    /// 다시 뜰 수 있는지. launchd가 띄운 인스턴스가 아니면 아무도 다시 띄우지 않는다. 횟수는 디스크에 둔다 — 메모리에만 두면 다시 뜰
    /// 때마다 0이 돼 끝없이 반복한다.
    public static func mayRelaunch(launchedByAgent: Bool, agentRegistered: Bool, relaunchCount: Int) -> Bool {
        launchedByAgent && agentRegistered && relaunchCount < maxRelaunches
    }

    /// 남은 시도가 있으면 `after`(없으면 그 차례의 지연) 뒤에 다시, 없으면 포기.
    private static func retry(_ state: State, after: Duration?, dropConnection: Bool) -> Step {
        guard state.attempts <= retryDelays.count else { return .giveUp(verificationFailed: state.sawVerificationFailure) }
        return .retry(after: after ?? retryDelays[state.attempts - 1], dropConnection: dropConnection)
    }
}
