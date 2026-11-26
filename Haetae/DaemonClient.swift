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
    /// 데몬은 사용자마다 줄을 세워 검사한다. 다른 사용자 실행 하나를 기다리는 시간까지 잡는다(Q63). 셋 이상 겹쳐 넘치면 다시 시도가
    /// 같은 실행의 결과를 받는다(데몬이 같은 uid 요청을 합친다).
    private static let collectTimeout: Duration = HaetaeLimits.maxRunDuration * 2 + .seconds(5)
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
        var waitedForRateLimit = false
        for delay in [Duration.zero] + Self.retryDelays {
            if delay > .zero { try await Task.sleep(for: delay) }
            // Release에서는 빌드가 다르면 서명 요구사항 때문에 응답이 오지 않는다. 응답 대신 디스크의 자기 빌드를 본다.
            if diskBuild() > identity.build { throw DaemonClientError.needsRelaunch }
            let data: Data
            do {
                data = try await call(timeout: Self.collectTimeout) { proxy, once in
                    proxy.collect { data, error in
                        once.resume(with: data.map(Result.success) ?? .failure(Self.decode(error)))
                    }
                }
            } catch HaetaeXPCError.updating {
                // 옛 데몬이 곧 끝난다. 연결을 놓아야 끝날 수 있다(D20).
                dropConnection()
                continue
            } catch HaetaeXPCError.rateLimited where !waitedForRateLimit {
                // 방금 다시 뜬 앱처럼 이 사용자의 검사가 막 시작됐다. 간격이 지나면 한 번 더 묻는다.
                waitedForRateLimit = true
                try await Task.sleep(for: HaetaeLimits.minCollectInterval)
                continue
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
                // 등록된 데몬(root 사본)이 이 앱보다 옛 빌드다. 다시 시도해도 launchd는 같은 옛 파일을 띄우니 바로 끝낸다. 연결을 놓기
                // 전에 사용자 종료로 알린다 — 그냥 끊으면 데몬이 비정상 종료와 검사 공백으로 적는다.
                await markUserQuit()
                dropConnection()
                throw DaemonClientError.staleDaemon
            }
            #endif
            return try CollectResult.decodeValidated(data)
        }
        throw sawVerificationFailure ? DaemonClientError.verificationFailed : DaemonClientError.noResponse
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
