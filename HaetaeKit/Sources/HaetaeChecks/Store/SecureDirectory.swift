import Foundation

public enum SecureDirectoryError: Error, Equatable {
    /// 이름이 `[A-Za-z0-9._-]`가 아니거나 `.`으로 시작한다(`.`으로 시작하는 이름은 임시 파일용).
    case invalidName
    /// 폴더나 파일이 이 프로세스 소유가 아니거나, 다른 사람에게 권한이 있거나, 일반 파일·폴더가 아니다.
    case untrusted
    case tooLarge
    /// 그 밖의 실패(errno).
    case system(Int32)
}

/// 데몬의 root 전용 저장 폴더(D7·D12). 폴더 0700, 파일 0600, 쓰기는 임시 파일 → `rename`(원자적).
/// 경로를 글자로 따라가지 않고 폴더 fd에서 `openat`으로 한 단계씩 연다 — 중간에 링크를 심어 다른 곳을 읽고 쓰게 하지 못하게.
public struct SecureDirectory: Sendable {
    public static let defaultRoot = "/Library/Application Support/Haetae"

    private let root: String

    /// - Parameter root: 절대 경로. 테스트에서는 임시 경로(`/private/var/folders/…`)를 넣는다.
    public init(root: String = SecureDirectory.defaultRoot) {
        self.root = root
    }

    /// 없으면 nil.
    public func read(_ name: String, in subdirectory: [String], maxBytes: Int) throws -> Data? {
        try withDirectory(subdirectory) { directory in
            try Self.validate(name)
            let fd = unsafe openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else {
                let code = errno
                if code == ENOENT { return nil }
                throw SecureDirectoryError.system(code)
            }
            defer { close(fd) }
            let info = try Self.checkOwned(fd, mode: S_IFREG)
            guard info.st_size <= maxBytes else { throw SecureDirectoryError.tooLarge }
            var data = Data()
            try readChunks(fd) {
                data.append(contentsOf: $0)
                if data.count > maxBytes { throw SecureDirectoryError.tooLarge }
            }
            return data
        }
    }

    /// 임시 파일에 쓰고 디스크까지 내린 뒤 `rename`한다. 도중에 꺼져도 예전 내용이나 새 내용 둘 중 하나만 남는다.
    /// macOS의 `fsync`는 드라이브 캐시까지 비우지 않아 `F_FULLFSYNC`를 쓴다 — 전원이 꺼진 뒤 기준값이 깨지면 안 된다.
    public func write(_ data: Data, to name: String, in subdirectory: [String]) throws {
        try withDirectory(subdirectory) { directory in
            try Self.validate(name)
            let temporary = ".\(name).\(UUID().uuidString)"
            let fd = unsafe openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw SecureDirectoryError.system(errno) }
            do {
                try Self.writeFully(data, to: fd)
                guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw SecureDirectoryError.system(errno) }
            } catch {
                close(fd)
                _ = unsafe unlinkat(directory, temporary, 0)
                throw error
            }
            close(fd)
            guard unsafe renameat(directory, temporary, directory, name) == 0 else {
                let code = errno
                _ = unsafe unlinkat(directory, temporary, 0)
                throw SecureDirectoryError.system(code)
            }
            _ = fsync(directory)
        }
    }

    /// 한 줄씩 쌓는 기록(`events.jsonl`)용. 파일이 `rotateAt`를 넘으면 `<name>.1`로 넘기고(예전 `.1`은 지움) 새로 쓴다 —
    /// 쏟아낸 기록으로 디스크를 채우지 못하게. 두 파일을 합쳐 `2 × rotateAt`을 넘지 않는다.
    public func append(_ data: Data, to name: String, in subdirectory: [String], rotateAt: Int) throws {
        try withDirectory(subdirectory) { directory in
            try Self.validate(name)
            for attempt in 0..<2 {
                let fd = unsafe openat(directory, name, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw SecureDirectoryError.system(errno) }
                defer { close(fd) }
                let info = try Self.checkOwned(fd, mode: S_IFREG)
                if attempt == 0, info.st_size > 0, Int(info.st_size) + data.count > rotateAt {
                    guard unsafe renameat(directory, name, directory, "\(name).1") == 0 else { throw SecureDirectoryError.system(errno) }
                    continue
                }
                try Self.writeFully(data, to: fd)
                guard fsync(fd) == 0 else { throw SecureDirectoryError.system(errno) }
                return
            }
        }
    }

    /// 같은 폴더 안에서 원자적으로 바꾼다(pending 기준값 확정, D24). `source`가 없으면 `.system(ENOENT)`.
    public func rename(_ source: String, to destination: String, in subdirectory: [String]) throws {
        try withDirectory(subdirectory) { directory in
            try Self.validate(source)
            try Self.validate(destination)
            guard unsafe renameat(directory, source, directory, destination) == 0 else { throw SecureDirectoryError.system(errno) }
            _ = fsync(directory)
        }
    }

    /// 루트부터 하위 폴더까지 한 단계씩 열고(없으면 0700으로 만듦) 소유자·권한을 확인한 fd로 `body`를 돌린다.
    private func withDirectory<T>(_ subdirectory: [String], _ body: (Int32) throws -> T) throws -> T {
        try subdirectory.forEach(Self.validate)
        guard root.hasPrefix("/"), !root.contains("\0") else { throw SecureDirectoryError.invalidName }
        // 루트 위쪽(`/Library/Application Support`)은 root 소유라 링크를 심을 수 없지만, 링크가 있으면 따라가지 않는다.
        if unsafe mkdir(root, 0o700) != 0, errno != EEXIST { throw SecureDirectoryError.system(errno) }
        var directory = unsafe open(root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard directory >= 0 else { throw SecureDirectoryError.system(errno) }
        defer { close(directory) }
        _ = try Self.checkOwned(directory, mode: S_IFDIR)
        for component in subdirectory {
            if unsafe mkdirat(directory, component, 0o700) != 0, errno != EEXIST { throw SecureDirectoryError.system(errno) }
            let next = unsafe openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw SecureDirectoryError.system(errno) }
            close(directory)
            directory = next
            _ = try Self.checkOwned(directory, mode: S_IFDIR)
        }
        return try body(directory)
    }

    /// 이 프로세스 소유이고, 기대한 종류이고, group·other 권한이 없어야 한다. 링크 수는 보지 않는다 — 폴더가 0700이라 남이 링크를 걸 수 없다.
    private static func checkOwned(_ fd: Int32, mode: mode_t) throws -> stat {
        var info = stat()
        guard unsafe fstat(fd, &info) == 0 else { throw SecureDirectoryError.system(errno) }
        guard info.st_mode & S_IFMT == mode, info.st_uid == geteuid(), info.st_mode & 0o077 == 0 else {
            throw SecureDirectoryError.untrusted
        }
        return info
    }

    private static func validate(_ name: String) throws {
        let bytes = name.utf8
        guard !bytes.isEmpty, bytes.count <= 255, bytes.first != UInt8(ascii: "."),
              bytes.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D })
        else { throw SecureDirectoryError.invalidName }
    }

    private static func writeFully(_ data: Data, to fd: Int32) throws {
        var offset = 0
        while offset < data.count {
            // offset < count라 baseAddress가 있고, 남은 길이만 넘긴다.
            let written = unsafe data.withUnsafeBytes { unsafe Darwin.write(fd, $0.baseAddress! + offset, $0.count - offset) }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                throw SecureDirectoryError.system(errno)
            }
        }
    }
}
