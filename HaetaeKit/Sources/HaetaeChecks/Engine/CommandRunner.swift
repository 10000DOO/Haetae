import Foundation
import Synchronization

/// 명령을 한 번 실행한 결과. `stdout`·`stderr`는 각각 `maxBytes`까지만 담는다.
///
/// 성공으로 보려면 `!timedOut && !terminatedBySignal && exitCode == 0`을 모두 확인한다.
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
}

public enum CommandError: Error, Equatable {
    case executableNotAllowed
    case nulInArgument
}

/// root 데몬이 CLI를 부르는 유일한 통로(D26). 셸을 거치지 않고, 환경은 고정값만 넘긴다.
///
/// 한 인스턴스는 명령을 한 번에 하나만 돌린다. 데몬 전체에서 하나만 만들어 나눠 쓴다.
public actor CommandRunner {
    /// root가 실행해도 되는 곳. 모두 SIP가 보호해서 사용자가 파일을 바꿀 수 없다.
    /// `/System/`은 넣지 않는다 — `/System/Volumes/Data` 아래는 사용자가 쓸 수 있다.
    private static let trustedPrefixes = ["/usr/bin/", "/bin/", "/usr/sbin/", "/sbin/", "/usr/libexec/"]
    private static let killGrace: Duration = .seconds(2)
    private static let drainGrace: Duration = .seconds(2)

    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    /// - Parameters:
    ///   - executable: `trustedPrefixes` 아래의 절대 경로.
    ///   - args: 그대로 넘긴다. 디스크에서 읽은 값을 넣을 때는 옵션으로 읽히지 않게 호출하는 쪽이 `--` 뒤에 둔다.
    ///   - timeout: 넘으면 SIGTERM, 2초 뒤 SIGKILL. 돌아오기까지는 최대 `timeout` + 6초가 걸린다.
    ///   - maxBytes: `stdout`·`stderr` 각각의 상한.
    /// - Throws: 취소되면 `CancellationError`. 앞선 명령을 기다리는 동안에는 차례가 와야 취소를 본다.
    public func run(_ executable: String, _ args: [String], timeout: Duration, maxBytes: Int) async throws -> CommandOutput {
        // 문자 단위로 보면 결합 문자가 붙은 `..`을 놓치므로 바이트로 본다.
        let path = executable.utf8
        guard Self.trustedPrefixes.contains(where: { path.starts(with: $0.utf8) }),
              !path.split(separator: UInt8(ascii: "/")).contains(where: { $0.elementsEqual("..".utf8) })
        else { throw CommandError.executableNotAllowed }
        // NUL이 있으면 Foundation이 ObjC 예외를 던진다. Swift에서 잡을 수 없어 데몬이 죽으므로 지우면 안 된다.
        guard !([executable] + args).contains(where: { $0.contains("\0") }) else { throw CommandError.nulInArgument }
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
        return try await Self.execute(executable, args, timeout: timeout, maxBytes: maxBytes)
    }

    private enum Event { case exited, eof, timeout, killDeadline, abandon, drainDeadline }

    private static func execute(_ executable: String, _ args: [String], timeout: Duration, maxBytes: Int) async throws -> CommandOutput {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = args
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        process.currentDirectoryURL = URL(filePath: "/")
        process.standardInput = FileHandle.nullDevice
        let pipes = [Pipe(), Pipe()]
        let buffers = [CappedBuffer(limit: maxBytes), CappedBuffer(limit: maxBytes)]
        process.standardOutput = pipes[0]
        process.standardError = pipes[1]

        let (events, sink) = AsyncStream.makeStream(of: Event.self)
        process.terminationHandler = { _ in sink.yield(.exited) }
        try process.run()
        let pid = process.processIdentifier
        // Foundation은 자식을 자기 프로세스 그룹의 리더로 띄우지만 문서에 없는 동작이다.
        // 확인됐을 때만 그룹에 시그널을 보낸다(아니면 데몬 자신의 그룹일 수 있다).
        let ownsGroup = getpgid(pid) == pid
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
                    forceKill(process, pid: pid, group: ownsGroup)
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
        forceKill(process, pid: pid, group: ownsGroup)
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

    private static func forceKill(_ process: Process, pid: pid_t, group: Bool) {
        if group {
            // 리더가 끝났어도 그룹에 프로세스가 남아 있는 동안은 이 번호가 다시 쓰이지 않는다. 비었으면 ESRCH로 끝난다.
            // 빈 그룹의 번호가 그 사이 다른 그룹에 다시 쓰이려면 pid가 한 바퀴 돌아야 한다.
            killpg(pid, SIGKILL)
        } else if process.isRunning {
            // 이미 끝난 pid는 다른 프로세스가 물려받았을 수 있다. root의 SIGKILL이 엉뚱한 곳에 가지 않게 확인한다.
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
