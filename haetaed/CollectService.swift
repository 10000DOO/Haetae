import Foundation
import HaetaeShared
import os

/// 연결 하나에 하나씩 만든다. 검사 엔진은 Phase 2(WO-12)에서 붙는다.
final class CollectService: NSObject, HaetaeXPCProtocol, Sendable {
    private let callerUID: uid_t
    private let build: Int
    private let validCall = OSAllocatedUnfairLock(initialState: false)

    /// 서명 요구사항을 통과한 호출이 한 번이라도 있었는지.
    var hadValidCall: Bool { validCall.withLock { $0 } }

    init(callerUID: uid_t, build: Int) {
        self.callerUID = callerUID
        self.build = build
    }

    func collect(withReply reply: @escaping @Sendable (Data?, NSError?) -> Void) {
        validCall.withLock { $0 = true }
        do {
            let result = CollectResult(findings: [], resolved: [], failedChecks: [], patternVersion: 0, daemonBuild: build)
            reply(try result.encodeValidated(), nil)
        } catch {
            Log.service.error("collect 응답 생성 실패 (\(String(describing: type(of: error)), privacy: .public))")
            reply(nil, HaetaeXPCError.internalError.nsError)
        }
    }

    func ack(_ fingerprintsJSON: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        validCall.withLock { $0 = true }
        reply(HaetaeXPCError.notImplemented.nsError)
    }

    func installPatterns(_ pack: Data, signature: Data, withReply reply: @escaping @Sendable (NSError?) -> Void) {
        validCall.withLock { $0 = true }
        reply(HaetaeXPCError.notImplemented.nsError)
    }

    func markUserQuit(withReply reply: @escaping @Sendable () -> Void) {
        validCall.withLock { $0 = true }
        Log.service.info("markUserQuit (uid \(self.callerUID))")
        reply()
    }
}
