import Foundation
import HaetaeChecks
import HaetaeShared
import os
import Synchronization

/// `CollectService`가 보는 데몬 수명 쪽. 작업을 세고 새 빌드를 확인한다.
protocol DaemonLifecycle: Sendable {
    /// `Task`를 띄우기 **전에** 동기로 부른다 — 끊김과 경쟁하지 않게(D15, Q36).
    func beginWork()
    func endWork()
    /// 디스크의 자기 번들 빌드가 더 높은지 보고, 높으면 진행 중인 작업이 끝난 뒤 종료하도록 표시한다(D20, Q30). 작업이 없으면
    /// 처음 알았을 때 종료 확인을 건다 — 부르는 쪽은 작업으로 세지 않는다.
    func checkForNewBuild() -> Bool
}

/// 연결을 받고 데몬 수명을 맡는다. 언제 끝낼지의 판단은 `DaemonLifecycleState`에 있고 여기서는 타이머와 `exit`만 한다.
final class ListenerDelegate: NSObject, NSXPCListenerDelegate, DaemonLifecycle, Sendable {
    private static let idleGrace: DispatchTimeInterval = .seconds(5)
    /// 새 빌드 때문에 끝낼 때 기다리는 시간. 방금 보낸 응답이 연결에서 나갈 틈을 준다.
    private static let newBuildGrace: DispatchTimeInterval = .seconds(1)

    private let configuration: DaemonConfiguration
    private let coordinator: CollectCoordinator
    private let state = Mutex(DaemonLifecycleState())

    init(configuration: DaemonConfiguration, coordinator: CollectCoordinator) {
        self.configuration = configuration
        self.coordinator = coordinator
        super.init()
        // 연결이 거부되기만 하면 작업이 생기지 않는다. 시작할 때도 한 번 걸어 둔다.
        scheduleExitCheck(.idle)
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard let requirement = configuration.appRequirement else {
            Log.listener.error("요구사항 없음 — 연결 거부")
            return false
        }
        // 메시지마다 다시 검사되므로 연결 도중 상대가 바뀌어도 끊긴다(3-7). resume 전에 걸어야 한다.
        newConnection.setCodeSigningRequirement(requirement)

        let uid = newConnection.effectiveUserIdentifier
        let service = CollectService(callerUID: uid, coordinator: coordinator, lifecycle: self)
        newConnection.exportedInterface = NSXPCInterface(with: (any HaetaeXPCProtocol).self)
        newConnection.exportedObject = service
        newConnection.invalidationHandler = { [self] in
            // 디스크에 새 빌드가 있으면 업데이트 때문에 끊긴 것이다 — 비정상 종료도 검증 실패도 세지 않고 작업으로도 세지 않는다
            // (`DaemonLifecycleState.connectionClosedDuringUpdate`). 남은 묶음은 종료 직전 `prepareForExit`가 적는다.
            if isNewBuildOnDisk() {
                if let wait = state.withLock({ $0.connectionClosedDuringUpdate() }) { scheduleExitCheck(wait) }
                return
            }
            let closed = service.closeState
            beginWork()
            Task {
                await coordinator.connectionClosed(callerUID: uid, userQuit: closed.userQuit, hadValidCall: closed.hadValidCall)
                state.withLock { $0.connectionClosed() }
                endWork()
            }
        }

        // resume 뒤에 올리면 바로 무효화된 연결이 먼저 줄여서 수가 어긋난다.
        state.withLock { $0.connectionOpened() }
        newConnection.resume()
        return true
    }

    func beginWork() {
        state.withLock { $0.beginWork() }
    }

    func endWork() {
        if let wait = state.withLock({ $0.endWork() }) { scheduleExitCheck(wait) }
    }

    func checkForNewBuild() -> Bool {
        guard isNewBuildOnDisk() else { return false }
        let (first, wait) = state.withLock { state in (!state.newBuildPending, state.noticeNewBuild()) }
        if first { Log.listener.notice("디스크에 새 빌드 — 진행 중인 작업이 끝나면 종료") }
        if let wait { scheduleExitCheck(wait) }
        return true
    }

    /// 한 번 알면 디스크를 다시 보지 않는다(서명 확인을 끊긴 연결마다 하지 않게).
    private func isNewBuildOnDisk() -> Bool {
        state.withLock { $0.newBuildPending } || configuration.hasNewerBuildOnDisk()
    }

    /// 지연 뒤에 조건을 보고, 묶어 둔 기록을 적은 뒤 한 번 더 본다 — 기록하는 동안 연결이나 작업이 들어오면 끝내지 않는다.
    private func scheduleExitCheck(_ wait: DaemonLifecycleState.Wait) {
        let ticket = state.withLock { $0.armExitCheck() }
        let delay = wait == .newBuild ? Self.newBuildGrace : Self.idleGrace
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            guard state.withLock({ $0.shouldExit(ticket) }) else { return }
            Task {
                await coordinator.prepareForExit()
                guard state.withLock({ $0.shouldExit(ticket) }) else { return }
                Log.listener.info("종료 (연결 0개이거나 새 빌드)")
                DaemonExit.now()
            }
        }
    }
}

/// 종료는 여기로만 한다. SIGTERM 처리와 예약된 종료가 겹쳐도 `exit`를 한 번만 부른다(동시에 부르는 `exit`는 정해진 동작이 아니다).
enum DaemonExit {
    private static let started = Atomic(false)

    static func now() {
        guard !started.exchange(true, ordering: .relaxed) else { return }
        exit(0)
    }
}
