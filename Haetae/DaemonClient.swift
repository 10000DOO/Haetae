import Foundation
import HaetaeAppCore
import HaetaeShared
import os
import Synchronization

/// 응답·오류·타임아웃 중 먼저 온 하나만 continuation을 깨운다(XPC 호출, 알림 등록 상한).
nonisolated final class Once<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, any Error>?>

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = Mutex(continuation)
    }

    func resume(with result: Result<T, any Error>) {
        continuation.withLock { $0.take() }?.resume(with: result)
    }
}

/// 데몬 연결 하나를 쥐고 있는다. 앱이 연결을 쥐고 있는 동안 데몬이 떠 있다(D15).
/// `FindingSource`·`PatternInstaller`는 `NonisolatedNonsendingByDefault`로 컴파일된 다른 모듈의 프로토콜이라, 채택한 메서드마다
/// `@MainActor`를 직접 붙인다 — 안 붙이면 nonisolated로 잡혀 연결 상태를 쓰지 못한다(WO-14 0번).
@MainActor
final class DaemonClient: FindingSource, PatternInstaller {
    /// 데몬은 사용자마다 줄을 세워 검사한다. 다른 사용자 실행 하나를 기다리는 시간까지 잡는다(Q63). 셋 이상 겹쳐 넘치면 다시 시도가
    /// 같은 실행의 결과를 받는다(데몬이 같은 uid 요청을 합친다). ack도 같다 — 데몬의 ack 확정이 다른 사용자 검사를 기다릴 수 있다.
    private static let collectTimeout: Duration = HaetaeLimits.maxRunDuration * 2 + .seconds(5)
    private static let installTimeout: Duration = .seconds(30)
    private static let quitTimeout: Duration = .seconds(2)

    private let identity: AppIdentity
    private var connection: NSXPCConnection?
    /// 쥐고 있던 연결이 끊겼을 때 부른다.
    var onInvalidated: (() -> Void)?

    init(identity: AppIdentity) {
        self.identity = identity
    }

    /// 재시도·재실행 판단은 `ReconnectPolicy`가 한다. 여기서는 XPC 호출과 결과 분류만 한다.
    @MainActor func collect() async throws -> CollectResult {
        var state = ReconnectPolicy.State()
        var wait: Duration = .zero
        while true {
            if wait > .zero { try await Task.sleep(for: wait) }
            if ReconnectPolicy.shouldRelaunch(diskBuild: diskBuild(), running: identity.build) { throw DaemonClientError.needsRelaunch }
            var data: Data?
            var daemonError: HaetaeXPCError?
            var attempt: ReconnectPolicy.Attempt
            do {
                data = try await call(timeout: Self.collectTimeout) { proxy, once in
                    proxy.collect { data, error in
                        once.resume(with: data.map(Result.success) ?? .failure(Self.decode(error)))
                    }
                }
                attempt = .reply(headerBuild: nil)
            } catch HaetaeXPCError.updating {
                // 마지막 시도라 다시 하지 않더라도 놓는다 — 연결을 쥐고 있으면 옛 데몬이 끝나지 못한다.
                dropConnection()
                attempt = .updating
            } catch HaetaeXPCError.rateLimited {
                daemonError = .rateLimited
                attempt = .rateLimited
            } catch let error as HaetaeXPCError {
                daemonError = error
                attempt = .daemonError
            } catch {
                // 무효화·중단·타임아웃. 데몬이 유휴 종료하는 순간과 겹쳐도 여기로 온다.
                let nsError = error as NSError
                Log.app.error("collect 실패 (\(nsError.domain, privacy: .public) \(nsError.code))")
                attempt = .noReply(signature: nsError.domain == NSCocoaErrorDomain
                    && [NSXPCConnectionInvalid, NSXPCConnectionCodeSigningRequirementFailure].contains(nsError.code))
            }
            #if DEBUG
            // Debug 요구사항에는 빌드 조건이 없어서 다른 빌드의 데몬과도 연결된다. 머리를 읽지 못하면 형식 오류로 바로 올린다.
            if let data { attempt = .reply(headerBuild: try CollectResult.decodeHeader(data).daemonBuild) }
            #endif
            switch ReconnectPolicy.next(after: attempt, running: identity.build, state: &state) {
            case .accept:
                guard let data else { throw HaetaeXPCError.internalError }
                return try await Self.decodeResult(data)
            case .relaunch:
                throw DaemonClientError.needsRelaunch
            case .staleDaemon:
                // 그냥 끊으면 데몬이 비정상 종료와 검사 공백으로 적는다.
                await markUserQuit()
                dropConnection()
                throw DaemonClientError.staleDaemon
            case .retry(let after, let drop):
                if drop { dropConnection() }
                wait = after
            case .rethrow:
                throw daemonError ?? HaetaeXPCError.internalError
            case .giveUp(let verificationFailed):
                throw verificationFailed ? DaemonClientError.verificationFailed : DaemonClientError.noResponse
            }
        }
    }

    /// 저장을 마친 뒤 받은 것을 알린다(D24). 0건이어도 빈 목록으로 부른다 — 데몬은 이것으로 검사 공백 표시를 지운다(Q67).
    /// 다시 시도하지 않는다 — 실패하면 파이프라인이 다음 검사에서 다시 저장·ack한다.
    @MainActor func ack(_ fingerprints: [String]) async throws {
        let data = try HaetaeXPC.encodeAck(fingerprints)
        let _: Bool = try await call(timeout: Self.collectTimeout) { proxy, once in
            proxy.ack(data) { error in once.resume(with: error.map { .failure(Self.decode($0)) } ?? .success(true)) }
        }
    }

    /// 패턴 팩을 데몬에 넣는다(WO-41 — 데몬은 아직 `notImplemented`).
    @MainActor func installPatterns(_ pack: Data, signature: Data) async throws {
        let _: Bool = try await call(timeout: Self.installTimeout) { proxy, once in
            proxy.installPatterns(pack, signature: signature) { error in once.resume(with: error.map { .failure(Self.decode($0)) } ?? .success(true)) }
        }
    }

    /// 응답은 4MB까지 온다 — 메인 액터 밖에서 푼다(WO-14 0번).
    @concurrent private nonisolated static func decodeResult(_ data: Data) async throws -> CollectResult {
        try CollectResult.decodeValidated(data)
    }

    /// 사용자가 끄거나 의도해서 다시 뜰 때만 부른다. 데몬이 비정상 종료로 기록하지 않게 한다(D28).
    func markUserQuit() async {
        // 쥔 연결이 없으면 데몬이 비정상 종료로 적을 끊김도 없다. 새로 연결하면 업데이트 뒤 새 데몬이 옛 앱을 검증 실패로 센다.
        guard connection != nil else { return }
        _ = try? await call(timeout: Self.quitTimeout) { (proxy, once: Once<Bool>) in
            proxy.markUserQuit { once.resume(with: .success(true)) }
        }
    }

    private func call<T: Sendable>(timeout: Duration, _ body: (any HaetaeXPCProtocol, Once<T>) -> Void) async throws -> T {
        let connection = activeConnection()
        return try await withCheckedThrowingContinuation { continuation in
            let once = Once(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { @Sendable error in
                once.resume(with: .failure(error))
            }
            guard let proxy = proxy as? any HaetaeXPCProtocol else {
                once.resume(with: .failure(HaetaeXPCError.internalError))
                return
            }
            body(proxy, once)
            // 타임아웃이 나도 연결은 끊지 않는다. 끊으면 데몬이 작업 도중 종료할 수 있다.
            Task {
                try? await Task.sleep(for: timeout)
                once.resume(with: .failure(DaemonClientError.timeout))
            }
        }
    }

    private func activeConnection() -> NSXPCConnection {
        if let connection { return connection }
        // 시스템 도메인에서만 찾는다. 사용자 도메인에 같은 이름을 심어도 무시된다(3-7).
        let connection = NSXPCConnection(machServiceName: HaetaeXPC.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: (any HaetaeXPCProtocol).self)
        // resume 전에 건다. 응답마다 다시 검사되므로 연결 도중 데몬이 바뀌어도 끊긴다.
        connection.setCodeSigningRequirement(identity.daemonRequirement)
        let id = ObjectIdentifier(connection)
        // 데몬이 끝나면(업데이트·충돌) 연결은 무효화되지 않고 중단만 된다. 같은 연결로 다시 보내면 launchd가 새 데몬을 띄우는데,
        // 그 데몬이 이 앱을 옛 빌드로 거부하면 검증 실패로 센다. 연결을 놓고 처음부터 다시 연결한다(무효화와 같이 처리).
        connection.interruptionHandler = { @Sendable [weak self] in
            Task { @MainActor in
                guard let self, self.connection.map(ObjectIdentifier.init) == id else { return }
                self.dropConnection()
                self.onInvalidated?()
            }
        }
        connection.invalidationHandler = { @Sendable [weak self] in
            Task { @MainActor in
                // 늦게 도착한 옛 연결의 무효화가 새 연결을 지우지 않게 한다.
                guard let self, self.connection.map(ObjectIdentifier.init) == id else { return }
                self.connection = nil
                self.onInvalidated?()
            }
        }
        connection.resume()
        self.connection = connection
        return connection
    }

    private func dropConnection() {
        connection?.invalidate()
        connection = nil
    }

    private func diskBuild() -> Int {
        struct Info: Decodable {
            let CFBundleVersion: String
        }
        let plist = Bundle.main.bundleURL.appending(path: "Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListDecoder().decode(Info.self, from: data) else {
            return identity.build
        }
        return Int(info.CFBundleVersion) ?? identity.build
    }

    /// 데몬은 코드만 보낸다. 우리 도메인이 아니면 XPC 자체의 오류(무효화·중단)다.
    private nonisolated static func decode(_ error: NSError?) -> any Error {
        guard let error else { return HaetaeXPCError.internalError }
        if error.domain == HaetaeXPC.errorDomain, let known = HaetaeXPCError(rawValue: error.code) {
            return known
        }
        return error
    }
}
