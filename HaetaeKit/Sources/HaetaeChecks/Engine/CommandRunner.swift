import Foundation
import LightweightCodeRequirements
import Synchronization

/// 명령을 한 번 실행한 결과. `stdout`·`stderr`는 각각 `maxBytes`까지만 담는다.
///
/// 성공 판정은 `succeeded`(`!timedOut && !terminatedBySignal && exitCode == 0`)로 한다.
/// SIGTERM을 받고 스스로 0으로 끝난 명령은 `timedOut`인데 `exitCode`가 0이다.
public struct CommandOutput: Sendable, Equatable {
    public let stdout: Data
    public let stderr: Data
    /// 시그널로 끝났으면 시그널 번호, SIGKILL 뒤에도 끝나지 않아 포기했으면 -1.
    public let exitCode: Int32
    public let terminatedBySignal: Bool
    /// 상한을 넘겨 잘렸거나, 프로세스가 끝난 뒤에도 파이프가 닫히지 않아 끝까지 읽었는지 알 수 없다.
    public let truncated: Bool
    public let timedOut: Bool

    /// 출력이 다 왔는지는 따로 `truncated`로 본다.
    public var succeeded: Bool { !timedOut && !terminatedBySignal && exitCode == 0 }
}

public enum CommandError: Error, Equatable {
    case executableNotAllowed
    case nulInArgument
}

/// root 데몬이 CLI를 부르는 유일한 통로(D26). 셸을 거치지 않고, 환경은 고정값만 넘긴다.
///
/// 한 인스턴스는 명령을 한 번에 하나만 돌린다. 데몬 전체에서 하나만 만들어 나눠 쓴다.
public actor CommandRunner {
    /// root가 실행해도 되는 곳. SIP가 보호하는 시스템 볼륨이지만, firmlink로 쓰기 가능한 Data 볼륨에 이어진 곳
    /// (`/usr/libexec/cups`)이 있어 `run`에서 볼륨을 따로 확인한다.
    /// `/System/`은 넣지 않는다 — `/System/Volumes/Data` 아래는 사용자가 쓸 수 있다.
    private static let trustedPrefixes = ["/usr/bin/", "/bin/", "/usr/sbin/", "/sbin/", "/usr/libexec/"]
    private static let killGrace: Duration = .seconds(2)
    private static let drainGrace: Duration = .seconds(2)

    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let selfExecutable: (path: String, requirement: LaunchCodeRequirement)?

    /// - Parameter selfExecutable: 해석 전용 프로세스로 띄울 데몬 자신(WO-48). 이 경로 하나만 시스템 볼륨 밖이어도 되고,
    ///   띄울 때 반드시 `requirement`(자기 cdhash)를 건다 — `/Applications`는 admin이 바꿀 수 있어서다.
    public init(selfExecutable: (path: String, requirement: LaunchCodeRequirement)? = nil) {
        self.selfExecutable = selfExecutable
    }

    /// `IsolatedParser`가 띄울 경로. 경로를 따로 넘기다 어긋나지 않게 러너가 가진 값을 쓴다.
    public nonisolated var selfExecutablePath: String? { selfExecutable?.path }

    /// - Parameters:
    ///   - executable: `trustedPrefixes` 아래의 절대 경로. 링크 없이 닿는, 시스템 볼륨의 파일이어야 한다.
    ///     `selfExecutable`의 경로는 예외다 — NUL만 확인하고 나머지는 커널의 서명 요구사항 확인으로 대신한다.
    ///   - args: 그대로 넘긴다. 디스크에서 읽은 값을 넣을 때는 옵션으로 읽히지 않게 호출하는 쪽이 `--` 뒤에 둔다.
    ///   - stdin: 주면 전용 스레드에서 써 넣고 닫는다(출력 읽기와 교착하지 않게). 없으면 `/dev/null`.
    ///     손자를 남기지 않는 명령에만 쓴다 — 그룹을 빠져나간 손자가 stdin을 쥐고 읽지 않으면 쓰기 스레드가 남는다.
    ///   - timeout: 넘으면 SIGTERM, 2초 뒤 SIGKILL. 돌아오기까지는 최대 `timeout` + 6초가 걸린다.
    ///   - maxBytes: `stdout`·`stderr` 각각의 상한.
    /// - Throws: 취소되면 `CancellationError`. 앞선 명령을 기다리는 동안에는 차례가 와야 취소를 본다.
    ///   서명 요구사항에 맞지 않으면 throw하지 않고, 커널이 exec 때 SIGKILL한 종료 상태로 돌아온다.
    public func run(_ executable: String, _ args: [String], stdin: Data? = nil, timeout: Duration, maxBytes: Int) async throws -> CommandOutput {
        // NUL이 있으면 Foundation이 ObjC 예외를 던진다. Swift에서 잡을 수 없어 데몬이 죽으므로 지우면 안 된다.
        guard !([executable] + args).contains(where: { $0.contains("\0") }) else { throw CommandError.nulInArgument }
        let requirement: LaunchCodeRequirement?
        // 다른 비교처럼 바이트로 본다(`==`는 유니코드 정규 동치까지 같게 본다).
        if let selfExecutable, executable.utf8.elementsEqual(selfExecutable.path.utf8) {
            requirement = selfExecutable.requirement
        } else {
            // 문자 단위로 보면 결합 문자가 붙은 `..`을 놓치므로 바이트로 본다.
            let path = executable.utf8
            guard Self.trustedPrefixes.contains(where: { path.starts(with: $0.utf8) }),
                  !path.split(separator: UInt8(ascii: "/")).contains(where: { $0.elementsEqual("..".utf8) }),
                  // 접두어는 대소문자·유니코드 변형으로 우회되므로 firmlink 예외는 이름이 아니라 파일이 있는 볼륨으로 거른다.
                  Self.isOnSystemVolume(executable)
            else { throw CommandError.executableNotAllowed }
            requirement = nil
        }
        precondition(maxBytes >= 0, "maxBytes는 0 이상")

        // actor는 await 사이에 다른 호출을 받으므로, 한 번에 하나만 돌리려면 차례를 직접 세운다.
        if isBusy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            isBusy = true
        }
        defer {
            if waiters.isEmpty { isBusy = false } else { waiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        return try await Self.execute(executable, args, stdin: stdin, requirement: requirement, timeout: timeout, maxBytes: maxBytes)
    }

    private enum Event { case exited, eof, timeout, killDeadline, abandon, drainDeadline }

    private static func execute(
        _ executable: String, _ args: [String], stdin: Data?, requirement: LaunchCodeRequirement?, timeout: Duration, maxBytes: Int
    ) async throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = args
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.currentDirectoryURL = URL(filePath: "/")
        // 커널이 exec 때 확인한다 — 확인과 실행 사이에 파일을 바꿔치기할 틈이 없다.
        process.launchRequirement = requirement
        let input = stdin.map { _ in Pipe() }
        process.standardInput = input ?? FileHandle.nullDevice
        let pipes = [Pipe(), Pipe()]
        let buffers = [CappedBuffer(limit: maxBytes), CappedBuffer(limit: maxBytes)]
        process.standardOutput = pipes[0]
        process.standardError = pipes[1]

        let (events, sink) = AsyncStream.makeStream(of: Event.self)
        process.terminationHandler = { _ in sink.yield(.exited) }
        try process.run()
        let pid = process.processIdentifier
        if let input, let stdin {
            // Foundation은 부모 쪽 읽기 끝을 닫으므로, 자식이 먼저 끝나면 쓰기가 EPIPE로 끝난다.
            // 그때 SIGPIPE가 오면 root 데몬이 죽으므로 이 fd에서는 끈다.
            let writer = input.fileHandleForWriting
            if fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 {
                Thread {
                    writeAll(stdin, to: writer.fileDescriptor)
                    try? writer.close()
                }.start()
            } else {
                // 막지 못하면 쓰지 않는다. 자식은 빈 입력을 받아 실패로 끝난다.
                try? writer.close()
            }
        }
        for (pipe, buffer) in zip(pipes, buffers) {
            let fd = pipe.fileHandleForReading.fileDescriptor
            pipe.fileHandleForReading.readabilityHandler = { handle in
                // `availableData`는 읽기 오류에 ObjC 예외를 던져 데몬을 죽일 수 있어 read(2)를 직접 부른다.
                var chunk = [UInt8](repeating: 0, count: 65_536)
                let (count, code) = chunk.withUnsafeMutableBytes {
                    let count = unsafe read(fd, $0.baseAddress, $0.count)
                    return (count, errno)
                }
                if count > 0 {
                    buffer.append(chunk[..<count])
                } else if count == 0 || code != EINTR {
                    if count < 0 { buffer.markTruncated() }
                    handle.readabilityHandler = nil
                    sink.yield(.eof)
                }
            }
        }
        defer {
            for pipe in pipes { pipe.fileHandleForReading.readabilityHandler = nil }
            sink.finish()
        }

        var exited = false
        var openPipes = pipes.count
        var timedOut = false
        await withDiscardingTaskGroup { group in
            group.addTask {
                for (delay, event) in [(timeout, Event.timeout), (killGrace, .killDeadline), (killGrace, .abandon)] {
                    do { try await Task.sleep(for: delay) } catch { return }
                    sink.yield(event)
                }
            }
            loop: for await event in events {
                switch event {
                case .exited:
                    exited = true
                    // 손자 프로세스가 파이프를 쥐고 있으면 EOF가 오지 않으므로 기한을 둔다.
                    group.addTask {
                        do { try await Task.sleep(for: drainGrace) } catch { return }
                        sink.yield(.drainDeadline)
                    }
                case .eof:
                    openPipes -= 1
                case .timeout where !exited:
                    timedOut = true
                    process.terminate()
                case .killDeadline:
                    forceKill(process, pid: pid)
                case .abandon where !exited, .drainDeadline:
                    break loop
                default:
                    break
                }
                if exited && openPipes == 0 { break }
            }
            group.cancelAll()
        }

        // 끝났든 취소됐든(취소되면 위 루프가 바로 끝난다) 명령이 남긴 프로세스를 root로 떠돌게 두지 않는다.
        // 리더가 끝난 뒤에도 출력을 쓰던 자식은 위에서 EOF나 기한까지 기다렸다.
        forceKill(process, pid: pid)
        try Task.checkCancellation()
        let out = buffers[0].snapshot()
        let err = buffers[1].snapshot()
        let running = process.isRunning
        return CommandOutput(
            stdout: out.data,
            stderr: err.data,
            exitCode: running ? -1 : process.terminationStatus,
            terminatedBySignal: !running && process.terminationReason == .uncaughtSignal,
            truncated: out.truncated || err.truncated || openPipes > 0,
            timedOut: timedOut
        )
    }

    /// 링크를 하나도 따라가지 않고 연 파일이 시스템(root) 볼륨에 있으면 경로 전체가 그 볼륨 안이라 검사 뒤에 바뀌지 않는다.
    /// 링크를 따라가면 쓰기 가능한 곳(firmlink인 `/usr/libexec/cups`)에 둔 링크를 검사 뒤 바꿔치기할 수 있다.
    private static func isOnSystemVolume(_ path: String) -> Bool {
        // O_NONBLOCK: FIFO를 열다 멈추지 않게.
        let fd = unsafe open(path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var fs = statfs()
        return unsafe fstatfs(fd, &fs) == 0 && fs.f_flags & UInt32(MNT_ROOTFS) != 0
    }

    private static func forceKill(_ process: Process, pid: pid_t) {
        // Foundation은 자식을 자기 프로세스 그룹의 리더로 띄운다(문서에 없는 동작). 커널은 쓰이고 있는 그룹 번호를
        // 새 pid로 주지 않으므로, 번호가 pid인 그룹은 자식이 만든 것뿐이다 — 자식이 먼저 끝났어도 그룹째 정리한다.
        // 리더가 끝났어도 그룹에 프로세스가 남아 있는 동안은 이 번호가 다시 쓰이지 않는다.
        // 빈 그룹의 번호가 그 사이 다른 그룹에 다시 쓰이려면 pid가 한 바퀴 돌아야 한다.
        if killpg(pid, SIGKILL) != 0, process.isRunning {
            // 그룹이 없으면(ESRCH) 자식만 죽인다. 이미 끝난 pid는 다른 프로세스가 물려받았을 수 있어 실행 중일 때만.
            kill(pid, SIGKILL)
        }
    }
}

/// 파이프 하나의 출력을 상한까지만 모은다. 넘친 뒤에도 호출은 받아서 버린다(파이프가 막히지 않게).
private final class CappedBuffer: Sendable {
    private struct State {
        var data = Data()
        var truncated = false
    }

    private let state = Mutex(State())
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ chunk: ArraySlice<UInt8>) {
        state.withLock {
            let room = limit - $0.data.count
            if chunk.count > room { $0.truncated = true }
            $0.data.append(contentsOf: chunk.prefix(room))
        }
    }

    func markTruncated() {
        state.withLock { $0.truncated = true }
    }

    func snapshot() -> (data: Data, truncated: Bool) {
        state.withLock { ($0.data, $0.truncated) }
    }
}

/// EINTR이 아닌 오류(자식이 먼저 닫음 — EPIPE)가 나면 그만둔다. 자식의 실패는 종료 상태로 드러난다.
private func writeAll(_ data: Data, to fd: Int32) {
    var offset = 0
    while offset < data.count {
        // offset < count라 baseAddress가 있고, 남은 길이만 넘긴다.
        let written = unsafe data.withUnsafeBytes { unsafe write(fd, $0.baseAddress! + offset, $0.count - offset) }
        if written > 0 {
            offset += written
        } else if written < 0, errno == EINTR {
            continue
        } else {
            return
        }
    }
}
