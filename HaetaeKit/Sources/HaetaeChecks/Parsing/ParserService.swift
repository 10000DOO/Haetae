import Foundation
import HaetaeShared
import LightweightCodeRequirements
import Security
import Synchronization

/// 해석 서비스(`haetae-parser`, Q48·Q54). launchd가 nobody로 띄우는 별도 실행 파일이다. 데몬의 전체 디스크 접근은 그대로
/// 받으므로(WO-51 실측 — TCC는 같은 앱 번들로 본다) 바이트를 나르기만 하고, 해석은 샌드박스에 든 자식이 한다(Q56).
/// 파일마다 자기 실행 파일을 `--parse`로 띄워 그 자식이 해석한다(launchd는 서비스를 1초에 한 번만 다시 띄워 주므로 직접 띄운다).
public enum ParserService {
    private static let idleLimit: Duration = .seconds(30)

    /// - Parameter daemonRequirement: 데몬의 서명 요구사항. 이것을 통과한 상대만 요청할 수 있다.
    public static func run(daemonRequirement: String) -> Never {
        // plist의 UserName이 먹지 않아 root로 떴어도 여기서 내린다.
        guard ParserProcess.dropPrivileges(), let me = selfExecutable() else {
            exit(ParserProcess.exitNoPermission)
        }
        let activity = Activity()
        let delegate = Delegate(runner: CommandRunner(selfExecutable: me), executable: me.path, requirement: daemonRequirement, activity: activity)
        let listener = NSXPCListener(machServiceName: HaetaeParserXPC.machServiceName)
        listener.delegate = delegate
        listener.resume()

        // 한가하면 끝낸다(데몬의 D15와 같은 이유). 계속 떠 있으면 앱을 업데이트한 뒤에도 옛 실행 파일로 남아,
        // 시작할 때 묶어 둔 cdhash와 디스크의 파일이 달라 자식을 띄울 때마다 막힌다. 다음 연결 때 launchd가 새 파일로 띄운다.
        let idleTimer = DispatchSource.makeTimerSource(queue: .global())
        idleTimer.schedule(deadline: .now() + .seconds(10), repeating: .seconds(10))
        idleTimer.setEventHandler { if activity.isIdle(for: idleLimit) { exit(0) } }
        idleTimer.resume()
        // delegate는 약한 참조다.
        withExtendedLifetime((delegate, listener, idleTimer)) { dispatchMain() }
    }

    /// 자기 실행 파일과 그 cdhash 요구사항. 해석 자식은 이것으로만 띄운다.
    /// cdhash로 묶는다 — 팀 ID로 묶으면 같은 팀이 서명한 예전 버전을 바꿔 둘 수 있다(D20).
    private static func selfExecutable() -> (path: String, requirement: LaunchCodeRequirement)? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        var running: SecRequirement?
        guard let path = Bundle.main.executablePath,
              unsafe SecCodeCopySelf([], &code) == errSecSuccess, let code,
              unsafe SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              unsafe SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let cdhash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              // 위 cdhash는 디스크의 서명이다. 뜬 뒤 파일을 바꿔 두면 바뀐 파일의 것이 나온다(리뷰 실측).
              // 실행 중인 코드가 이 cdhash인지 확인한다 — 다르면 공격자 파일을 요구사항으로 묶게 된다.
              unsafe SecRequirementCreateWithString("cdhash H\"\(lowercaseHex(cdhash))\"" as CFString, [], &running) == errSecSuccess,
              SecCodeCheckValidity(code, [], running) == errSecSuccess
        else { return nil }
        guard let requirement = try? LaunchCodeRequirement.allOf(requirement: { CodeDirectoryHash(cdhash) }) else { return nil }
        return (path, requirement)
    }

    /// 진행 중인 요청 수와 마지막 요청 시각.
    private final class Activity: Sendable {
        private let state = Mutex((inFlight: 0, last: ContinuousClock.now))

        func begin() {
            state.withLock { $0.inFlight += 1 }
        }

        func end() {
            state.withLock {
                $0.inFlight -= 1
                $0.last = .now
            }
        }

        func isIdle(for limit: Duration) -> Bool {
            state.withLock { $0.inFlight == 0 && ContinuousClock.now - $0.last > limit }
        }
    }

    private final class Delegate: NSObject, NSXPCListenerDelegate, Sendable {
        private let runner: CommandRunner
        private let executable: String
        private let requirement: String
        private let activity: Activity

        init(runner: CommandRunner, executable: String, requirement: String, activity: Activity) {
            self.runner = runner
            self.executable = executable
            self.requirement = requirement
            self.activity = activity
        }

        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
            let session = Session(runner: runner, executable: executable, activity: activity)
            // 메시지마다 다시 검사된다. resume 전에 걸어야 한다.
            newConnection.setCodeSigningRequirement(requirement)
            newConnection.exportedInterface = NSXPCInterface(with: (any HaetaeParserXPCProtocol).self)
            newConnection.exportedObject = session
            // 데몬이 기다리다 끊으면 그 요청도 버린다 — 버려진 요청이 줄을 서서 다음 파일까지 늦추지 않게.
            newConnection.invalidationHandler = { session.cancelAll() }
            newConnection.resume()
            return true
        }
    }

    /// 연결 하나에 하나. 데몬은 파일마다 연결을 새로 연다.
    private final class Session: NSObject, HaetaeParserXPCProtocol, Sendable {
        private let runner: CommandRunner
        private let executable: String
        private let activity: Activity
        private let state = Mutex((tasks: [Task<Void, Never>](), cancelled: false))

        init(runner: CommandRunner, executable: String, activity: Activity) {
            self.runner = runner
            self.executable = executable
            self.activity = activity
        }

        func parse(_ data: Data, format: String, withReply reply: @escaping @Sendable (Data?, Bool) -> Void) {
            guard data.count <= ParserLimits.maxInputBytes, ParseFormat(rawValue: format) != nil else { return reply(nil, false) }
            activity.begin()
            let task = Task {
                defer { activity.end() }
                do {
                    let output = try await runner.run(
                        executable, ["--parse", format], stdin: data, timeout: .seconds(5), maxBytes: ParserLimits.maxOutputBytes
                    )
                    // 시간 초과가 아닌 SIGKILL은 서명 요구사항에 걸린 것이고(디스크의 빌드가 바뀜), 77은 권한·샌드박스·자원 상한을
                    // 못 건 것이다(OS가 샌드박스 호출을 막음) — 둘 다 파일 탓이 아니다.
                    let blocked = !output.terminatedBySignal && output.exitCode == ParserProcess.exitNoPermission
                    let unavailable = blocked || (output.terminatedBySignal && output.exitCode == SIGKILL && !output.timedOut)
                    reply(output.succeeded && !output.truncated ? output.stdout : nil, unavailable)
                } catch {
                    reply(nil, true)
                }
            }
            // 연결이 먼저 끊겼으면 넣자마자 취소한다 — `cancelAll`이 이 Task를 보지 못했을 수 있다.
            let alreadyCancelled = state.withLock {
                $0.tasks.append(task)
                return $0.cancelled
            }
            if alreadyCancelled { task.cancel() }
        }

        func cancelAll() {
            state.withLock {
                $0.cancelled = true
                return $0.tasks
            }.forEach { $0.cancel() }
        }
    }
}
