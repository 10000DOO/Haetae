import Foundation
import HaetaeChecks
import HaetaeShared
import os
import Synchronization

/// 연결 하나에 하나씩 만든다. XPC 메서드를 `CollectCoordinator`로 넘기고 오류를 NSError로 바꾸기만 한다(Q23).
/// 메서드는 4개로 고정한다(D27).
final class CollectService: NSObject, HaetaeXPCProtocol, Sendable {
    struct CloseState {
        /// 서명 요구사항을 통과한 호출이 한 번이라도 있었는지.
        var hadValidCall = false
        var userQuit = false
    }

    private let callerUID: uid_t
    private let coordinator: CollectCoordinator
    private let lifecycle: any DaemonLifecycle
    private let state = Mutex(CloseState())

    /// 연결이 끊길 때 읽는다.
    var closeState: CloseState { state.withLock { $0 } }

    init(callerUID: uid_t, coordinator: CollectCoordinator, lifecycle: any DaemonLifecycle) {
        self.callerUID = callerUID
        self.coordinator = coordinator
        self.lifecycle = lifecycle
    }

    func collect(withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        markValidCall()
        // 디스크에 새 빌드가 있으면 이 데몬은 곧 끝난다. 검사를 돌리지 않는다 — 돌리면 새 앱이 응답을 버려(Release는 서명 요구사항,
        // Debug는 빌드 비교) 그 응답의 해결·검사 공백만 사라진다. 이 응답은 작업으로 세지 않는다 — 되풀이해 종료를 미루지 못하게.
        // Release에서는 `collect`가 오지 않을 수도 있어 끊긴 연결에서도 본다(ListenerDelegate).
        if lifecycle.checkForNewBuild() {
            reply(nil, HaetaeXPCError.updating.nsError)
            return
        }
        lifecycle.beginWork()
        Task {
            defer { lifecycle.endWork() }
            do throws(HaetaeXPCError) {
                reply(try await coordinator.collect(callerUID: callerUID), nil)
            } catch {
                reply(nil, error.nsError)
            }
        }
    }

    func ack(_ fingerprintsJSON: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        markValidCall()
        lifecycle.beginWork()
        Task {
            defer { lifecycle.endWork() }
            do throws(HaetaeXPCError) {
                try await coordinator.ack(fingerprintsJSON, callerUID: callerUID)
                reply(nil)
            } catch {
                reply(error.nsError)
            }
        }
    }

    func installPatterns(_ pack: Data, signature: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        markValidCall()
        do throws(HaetaeXPCError) {
            try coordinator.ensureNotRolledBack()
        } catch {
            reply(error.nsError)
            return
        }
        reply(HaetaeXPCError.notImplemented.nsError)
    }

    /// 순서를 바꾸지 않는다: 되돌리기 확인 → `userQuit` 표시 → 기록 Task → 응답. 표시를 `await` 뒤에 세우면 앱의 2초 대기가 먼저
    /// 끝나 연결이 끊기고 비정상 종료로 기록된다(WO-12 3번).
    func markUserQuit(withReply reply: @escaping @Sendable () -> Void) {
        markValidCall()
        guard !coordinator.isRolledBack else {
            reply()
            return
        }
        state.withLock { $0.userQuit = true }
        // 로그아웃 뒤에도 확인할 수 있게 디스크에 남는 수준으로 적는다.
        Log.service.notice("markUserQuit (uid \(self.callerUID))")
        lifecycle.beginWork()
        Task {
            defer { lifecycle.endWork() }
            await coordinator.userQuit(callerUID: callerUID)
        }
        reply()
    }

    private func markValidCall() {
        state.withLock { $0.hadValidCall = true }
    }
}
