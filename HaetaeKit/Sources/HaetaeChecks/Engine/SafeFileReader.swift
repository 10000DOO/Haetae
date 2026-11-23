import CryptoKit
import Foundation
import Synchronization

public enum SafeFileError: Error, Equatable {
    /// 절대 경로가 아니거나 NUL이 들어 있다.
    case invalidPath
    /// 경로의 어느 성분이 심볼릭 링크다. `/etc`·`/var`·`/tmp`도 링크라서 `/private/…`로 적어야 한다.
    case symlink
    /// FIFO, 장치, 디렉터리 등.
    case notRegularFile
    case ownerMismatch
    /// root로 읽을 파일의 폴더가 root 소유가 아니거나, group·other가 쓸 수 있거나, 사용자가 붙인 볼륨에 있다.
    case untrustedDirectory
    /// root만 읽을 수 있는 파일이라 내용을 돌려주지 않는다. `metadata`를 쓴다(D25).
    case rootOnly
    case tooLarge
    /// 그 밖의 실패. 값은 errno — 파일이 없으면 `ENOENT`, 그 사용자가 못 읽으면 `EACCES`,
    /// 내려받지 않은 iCloud 파일이면 `EDEADLK`, 멈춘 읽기가 쌓였으면 `EAGAIN`.
    case system(Int32)
}

public struct FileMetadata: Sendable, Equatable {
    /// 소문자 hex 64자.
    public let sha256: String
    public let size: Int64
    public let modified: Date
}

/// root 데몬이 파일을 읽는 통로(D25). 링크·FIFO·남의 파일로 root 전용 파일을 빼내거나 데몬을 멈추게 하는 것을 막는다.
public struct SafeFileReader: Sendable {
    public init() {}

    /// `user` 권한으로 열어서, `user`가 소유한 일반 파일이고 `maxBytes` 이하일 때만 내용을 돌려준다.
    /// 링크 수는 보지 않는다 — 아무 사용자나 남의 파일에 하드링크를 걸어 링크 수를 올릴 수 있다(Q43·Q46).
    /// 남의 파일에 건 하드링크는 소유자 확인과 사용자 권한이 막고, 자기 파일에 건 것은 읽어도 해가 없다.
    ///
    /// 시스템 파일은 `UserRecord.root`로 읽는다. 이때는 root만 쓸 수 있는 폴더 안의 root 소유 파일만 받는다.
    /// 누구나 읽을 수 있는 파일만 내용을 돌려준다. 그 결과는 모든 사용자에게 가기 때문이다(D29, T1).
    ///
    /// 데몬이 root가 아니면(테스트) 권한을 바꾸지 않고 자기 권한으로 읽는다 — 낮출 권한이 없으니 더 읽게 되지도 않는다.
    /// - Throws: `SafeFileError`. 취소되면 읽기가 커널에서 멈춰 있어도 바로 `CancellationError`.
    public func read(path: String, asUser user: UserRecord, maxBytes: Int) async throws -> Data {
        try validate(path)
        precondition(maxBytes >= 0, "maxBytes는 0 이상")
        return try await onDedicatedThread(limitedTo: user.uid == 0 ? nil : user.uid) { try readAs(user, path: path, maxBytes: maxBytes) }
    }

    /// root 전용 파일의 내용 대신 해시·크기·수정 시각만 돌려준다. `UserRecord.root`로 읽을 때와 같은 조건만 받는다.
    /// - Throws: `SafeFileError`. 취소되면 `CancellationError`.
    public func metadata(path: String, maxBytes: Int) async throws -> FileMetadata {
        try validate(path)
        precondition(maxBytes >= 0, "maxBytes는 0 이상")
        return try await onDedicatedThread(limitedTo: nil) {
            let (fd, info) = try openRootFile(path)
            defer { close(fd) }
            guard info.st_size <= maxBytes else { throw SafeFileError.tooLarge }
            var hasher = SHA256()
            var total = 0
            try readChunks(fd) {
                total += $0.count
                if total > maxBytes { throw SafeFileError.tooLarge }
                hasher.update(data: $0)
            }
            return FileMetadata(
                sha256: hasher.finalize().map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined(),
                // 읽는 사이 파일이 바뀌어도 해시와 크기가 같은 내용을 가리키게 한다.
                size: Int64(total),
                modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec))
            )
        }
    }

    private func validate(_ path: String) throws {
        // NUL 뒤는 C 문자열에서 잘려 다른 경로가 열린다.
        guard path.hasPrefix("/"), !path.contains("\0") else { throw SafeFileError.invalidPath }
    }
}

/// `KAUTH_UID_NONE`·`KAUTH_GID_NONE`(sys/kauth.h). 식이 든 매크로라 Swift로 들어오지 않는다.
private let kauthNone: UInt32 = ~0 - 100

/// 사용자별로 동시에 도는 스레드 수. 커널에서 멈춘 채 버려진 스레드도 센다. 쌓여서 프로세스의 스레드 한도에 닿으면
/// `Thread.start()`가 아무 말 없이 블록을 실행하지 않아, 데몬의 다른 일까지 멈춘다.
/// 사용자별로 세는 것은 한 사용자가 자기 폴더의 멈춘 마운트로 다른 사용자의 읽기를 막지 못하게 하려는 것이다.
/// root 전용 폴더 읽기는 세지 않는다.
private let userThreads = Mutex<[uid_t: Int]>([:])
private let maxUserThreads = 8
/// 모든 읽기 스레드의 마지막 상한. 정상이면 닿지 않는다 — root 읽기도 사용자 영역을 지나는 경로를 받으면 멈출 수 있다.
private let allThreads = Atomic<Int>(0)
private let maxAllThreads = 64

/// 한 번 쓰고 끝나는 스레드에서 `body`를 돌린다. 권한은 스레드 단위로 바뀌는데, 동시성 풀 스레드에서 바꾸면
/// 되돌리지 못했을 때 다른 작업이 그 권한으로 돈다. 이 스레드는 바뀐 권한과 함께 사라진다.
/// 파일 읽기가 커널에서 멈춰도(멈춘 네트워크 볼륨 등) 취소되면 스레드를 버리고 바로 돌아온다.
/// - Parameter uid: 사용자가 고를 수 있는 경로면 그 사용자. 그 사용자 몫이 동시에 `maxUserThreads`개를 넘으면 `.system(EAGAIN)`.
func onDedicatedThread<T: Sendable>(limitedTo uid: uid_t?, _ body: @escaping @Sendable () throws -> T) async throws -> T {
    try Task.checkCancellation()
    guard allThreads.add(1, ordering: .relaxed).newValue <= maxAllThreads else {
        allThreads.subtract(1, ordering: .relaxed)
        throw SafeFileError.system(EAGAIN)
    }
    if let uid {
        let admitted = userThreads.withLock { counts in
            guard counts[uid, default: 0] < maxUserThreads else { return false }
            counts[uid, default: 0] += 1
            return true
        }
        guard admitted else {
            allThreads.subtract(1, ordering: .relaxed)
            throw SafeFileError.system(EAGAIN)
        }
    }
    let release: @Sendable () -> Void = {
        if let uid {
            userThreads.withLock { counts in
                let left = counts[uid, default: 1] - 1
                counts[uid] = left > 0 ? left : nil
            }
        }
        allThreads.subtract(1, ordering: .relaxed)
    }
    let slot = ContinuationSlot<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            slot.store(continuation)
            // 이미 취소된 채 들어왔으면 onCancel이 slot을 비우기 전에 돌았을 수 있다. 스레드는 띄우지 않는다.
            if Task.isCancelled {
                release()
                slot.take()?.resume(throwing: CancellationError())
                return
            }
            Thread {
                // 내려받지 않은 iCloud 파일은 내려받기를 기다리지 않고 바로 EDEADLK로 실패하게 한다.
                _ = setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)
                let result = Result { try body() }
                release()
                slot.take()?.resume(with: result)
            }.start()
        }
    } onCancel: {
        slot.take()?.resume(throwing: CancellationError())
    }
}

/// 스레드·취소 중 먼저 온 쪽만 continuation을 깨운다.
private final class ContinuationSlot<T: Sendable>: Sendable {
    private let state = Mutex<CheckedContinuation<T, any Error>?>(nil)

    func store(_ continuation: CheckedContinuation<T, any Error>) {
        state.withLock { $0 = continuation }
    }

    func take() -> CheckedContinuation<T, any Error>? {
        state.withLock { $0.take() }
    }
}

private func readAs(_ user: UserRecord, path: String, maxBytes: Int) throws -> Data {
    let (fd, info) = try user.uid == 0 ? openRootFile(path) : openUserFile(path, as: user)
    defer { close(fd) }
    // 폴더가 닫혀 있어 남이 못 읽는 파일(`/private/var/root` 안의 644 등)은 여기서 걸러지지 않는다.
    guard user.uid != 0 || info.st_mode & S_IROTH != 0 else { throw SafeFileError.rootOnly }
    guard info.st_size <= maxBytes else { throw SafeFileError.tooLarge }

    // fstat 뒤에 파일이 커질 수 있어 읽으면서도 센다.
    var data = Data()
    try readChunks(fd) {
        data.append(contentsOf: $0)
        if data.count > maxBytes { throw SafeFileError.tooLarge }
    }
    return data
}

/// 그 사용자 권한으로 연다. 권한은 여는 동안만 바꾼다 — 열린 fd로 읽을 때는 권한을 다시 보지 않는다.
// Apple이 권하지 않는 API지만, 커널이 그 사용자가 못 들어가는 경로를 막아 주는 한 겹을 위해 쓴다(D25, Q41).
@diagnose(DeprecatedDeclaration, as: ignored)
private func openUserFile(_ path: String, as user: UserRecord) throws -> (fd: Int32, info: stat) {
    let switched = geteuid() == 0
    if switched {
        guard pthread_setugid_np(user.uid, user.gid) == 0 else { throw SafeFileError.system(errno) }
    }
    // 되돌리기에 실패해도 이 스레드는 곧 끝나므로 다른 작업에 번지지 않는다.
    defer { if switched { pthread_setugid_np(kauthNone, kauthNone) } }
    if switched {
        // 호출이 성공을 돌려주고도 바꾸지 않았다면 root로 열게 된다. 실제로 바뀌었는지 본다.
        var uid = uid_t(), gid = gid_t()
        guard unsafe pthread_getugid_np(&uid, &gid) == 0, uid == user.uid, gid == user.gid else { throw SafeFileError.system(EPERM) }
    }

    let fd = unsafe open(path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw openError(errno) }
    let info = try regularFileInfo(fd)
    guard info.st_uid == user.uid else { close(fd); throw SafeFileError.ownerMismatch }
    return (fd, info)
}

/// root로 열되, root만 쓸 수 있는 폴더 안의 root 소유 일반 파일만 받는다.
private func openRootFile(_ path: String) throws -> (fd: Int32, info: stat) {
    // 결합 문자가 붙은 "/"를 놓치지 않게 바이트로 자른다. validate()가 "/"로 시작함을 보장한다.
    let bytes = path.utf8
    guard let slash = bytes.lastIndex(of: UInt8(ascii: "/")) else { throw SafeFileError.invalidPath }
    let parent = slash == bytes.startIndex ? "/" : String(decoding: bytes[..<slash], as: UTF8.self)
    let name = String(decoding: bytes[bytes.index(after: slash)...], as: UTF8.self)

    let dir = unsafe open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
    guard dir >= 0 else { throw openError(errno) }
    defer { close(dir) }
    var dirInfo = stat()
    guard unsafe fstat(dir, &dirInfo) == 0 else { throw SafeFileError.system(errno) }
    // 폴더 ACL은 보지 않는다.
    guard dirInfo.st_uid == 0, dirInfo.st_mode & (S_IWGRP | S_IWOTH) == 0 else { throw SafeFileError.untrustedDirectory }
    // 사용자가 붙인 볼륨(DMG·USB·FSKit)은 소유자를 무시하게 마운트할 수 있어, root에게 모든 파일이 root 소유로 보일 수 있다.
    var volume = statfs()
    guard unsafe fstatfs(dir, &volume) == 0 else { throw SafeFileError.system(errno) }
    guard volume.f_owner == 0, volume.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0 else { throw SafeFileError.untrustedDirectory }

    // 확인한 그 폴더를 기준으로 연다. 사이에 경로가 바뀌어도 다른 폴더의 파일을 열지 않는다.
    // `name`이 ".."이어도 디렉터리라서 아래에서 거부된다.
    let fd = unsafe openat(dir, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw openError(errno) }
    let info = try regularFileInfo(fd)
    guard info.st_uid == 0 else { close(fd); throw SafeFileError.ownerMismatch }
    return (fd, info)
}

/// O_NOFOLLOW(_ANY)가 링크를 만나면 ELOOP다.
private func openError(_ code: Int32) -> SafeFileError {
    code == ELOOP ? .symlink : .system(code)
}

/// 일반 파일이 아니면 fd를 닫고 throw한다. O_NONBLOCK으로 열어 두면 쓰는 쪽이 없는 FIFO도 여기까지 멈추지 않고 온다.
private func regularFileInfo(_ fd: Int32) throws -> stat {
    var info = stat()
    guard unsafe fstat(fd, &info) == 0 else {
        let code = errno
        close(fd)
        throw SafeFileError.system(code)
    }
    guard info.st_mode & S_IFMT == S_IFREG else {
        close(fd)
        throw SafeFileError.notRegularFile
    }
    return info
}

func readChunks(_ fd: Int32, _ body: (ArraySlice<UInt8>) throws -> Void) throws {
    var chunk = [UInt8](repeating: 0, count: 65_536)
    while true {
        let (count, code) = chunk.withUnsafeMutableBytes {
            let count = unsafe read(fd, $0.baseAddress, $0.count)
            return (count, errno)
        }
        if count > 0 {
            try body(chunk[..<count])
        } else if count == 0 {
            return
        } else if code != EINTR {
            throw SafeFileError.system(code)
        }
    }
}
