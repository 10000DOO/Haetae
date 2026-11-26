import Foundation
import HaetaeShared
import os
import Synchronization

nonisolated enum DaemonClientError: Error {
    /// 디스크의 앱이나 데몬이 더 새 빌드다. 앱이 다시 떠야 한다(D20).
    case needsRelaunch
    /// Debug에서만: 데몬이 더 옛 빌드다.
    case staleDaemon
    /// 다시 시도해도 데몬이 서명 요구사항을 통과하지 못했다.
    case verificationFailed
    case noResponse
    case timeout
}

/// XPC 응답·오류 핸들러·타임아웃 중 먼저 온 하나만 continuation을 깨운다.
private nonisolated final class Once<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, any Error>?>

    init(_ continuation: CheckedContinuation<T, any Error>) {
        self.continuation = Mutex(continuation)
    }

    func resume(with result: Result<T, any Error>) {
        continuation.withLock { $0.take() }?.resume(with: result)
    }
}

/// 데몬 연결 하나를 쥐고 있는다. 앱이 연결을 쥐고 있는 동안 데몬이 떠 있다(D15).
@MainActor
final class DaemonClient {
    /// shortcut: 모든 호출이 검사 한 바퀴 상한 + 5초다, `collect`가 다른 사용자 실행을 기다리는 시간까지 잡을 때(WO-12) `collect`만 나눈다.
    private static let callTimeout: Duration = HaetaeLimits.maxRunDuration + .seconds(5)
    private static let quitTimeout: Duration = .seconds(2)
    /// 무효화된 뒤 다시 시도하기 전에 기다리는 시간. 옛 데몬이 꺼지고 새 데몬이 뜰 시간을 준다(D20).
    private static let retryDelays: [Duration] = [.seconds(5), .seconds(15), .seconds(30)]

    private let identity: AppIdentity
    private var connection: NSXPCConnection?
    /// 쥐고 있던 연결이 끊겼을 때 부른다.
    var onInvalidated: (() -> Void)?

    init(identity: AppIdentity) {
        self.identity = identity
    }

    func collect() async throws -> CollectResult {
        var sawVerificationFailure = false
        #if DEBUG
        var sawStaleDaemon = false
        #endif
        for delay in [Duration.zero] + Self.retryDelays {
            if delay > .zero { try await Task.sleep(for: delay) }
            // Release에서는 빌드가 다르면 서명 요구사항 때문에 응답이 오지 않는다. 응답 대신 디스크의 자기 빌드를 본다.
            if diskBuild() > identity.build { throw DaemonClientError.needsRelaunch }
            let data: Data
            do {
                data = try await call(timeout: Self.callTimeout) { proxy, once in
                    proxy.collect { data, error in
                        once.resume(with: data.map(Result.success) ?? .failure(Self.decode(error)))
                    }
                }
            } catch let error as HaetaeXPCError {
                throw error
            } catch {
                // 무효화·중단·타임아웃. 데몬이 유휴 종료하는 순간과 겹쳐도 여기로 온다.
                let nsError = error as NSError
                Log.app.error("collect 실패 (\(nsError.domain, privacy: .public) \(nsError.code))")
                if nsError.domain == NSCocoaErrorDomain,
                   [NSXPCConnectionInvalid, NSXPCConnectionCodeSigningRequirementFailure].contains(nsError.code) {
                    sawVerificationFailure = true
                }
                continue
            }
            #if DEBUG
            // Debug 요구사항에는 빌드 조건이 없어서 다른 빌드의 데몬과도 연결된다.
            let daemonBuild = try CollectResult.decodeHeader(data).daemonBuild
            if daemonBuild > identity.build { throw DaemonClientError.needsRelaunch }
            if daemonBuild < identity.build {
                // 연결을 쥐고 있으면 옛 데몬이 유휴 종료하지 못한다.
                dropConnection()
                sawStaleDaemon = true
                continue
            }
            #endif
            return try CollectResult.decodeValidated(data)
        }
        #if DEBUG
        if sawStaleDaemon { throw DaemonClientError.staleDaemon }
        #endif
        throw sawVerificationFailure ? DaemonClientError.verificationFailed : DaemonClientError.noResponse
    }

    /// 사용자가 끄거나 의도해서 다시 뜰 때만 부른다. 데몬이 비정상 종료로 기록하지 않게 한다(D28).
    func markUserQuit() async {
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
