import Foundation

/// 로그인할 수 있는 사람 계정 하나. 검사가 그 사용자 파일을 읽을 때 `SafeFileReader`에 넘긴다.
public struct UserRecord: Sendable, Equatable {
    public let name: String
    public let uid: uid_t
    public let gid: gid_t
    public let home: String

    /// 시스템 파일을 읽을 때 `SafeFileReader`에 넘긴다.
    public static let root = UserRecord(name: "root", uid: 0, gid: 0, home: "/private/var/root")
}

public enum UserDirectoryError: Error, Equatable {
    case lookupFailed
}

/// 계정 정보는 계정 DB에서 가져온다(D25). `/Users`를 나열하면 누구나 쓸 수 있는 `/Users/Shared` 같은 폴더가 섞인다.
public enum UserDirectory {
    private static let timeout: Duration = .seconds(10)
    private static let maxBytes = 1_000_000

    /// 데몬은 호출 사용자 1명만 다룬다(D29). 다른 계정의 홈이 멈추거나 깨져 있어도 이 사용자의 검사에 번지지 않게 이 계정만 본다.
    /// - Returns: uid가 501 미만이거나, 계정이 없거나, 홈·그룹이 없거나, 홈이 링크이거나 소유자가 다르면 nil.
    ///   호출 사용자가 nil이면 그 사용자 범위 검사는 "발견 없음"이 아니라 실패로 올린다(T12).
    /// - Throws: 조회 명령이 실패하면 `lookupFailed`. 취소되면 `CancellationError`.
    public static func user(uid: uid_t, runner: CommandRunner) async throws -> UserRecord? {
        guard uid >= 501 else { return nil }
        let list = try await runner.run("/usr/bin/dscl", [".", "-list", "/Users", "UniqueID"], timeout: timeout, maxBytes: maxBytes)
        guard list.succeeded, !list.truncated else { throw UserDirectoryError.lookupFailed }
        // 음수 uid(nobody = -2)는 uid_t로 바뀌지 않아 맞지 않는다.
        var found: Substring?
        for line in String(decoding: list.stdout, as: UTF8.self).split(separator: "\n") {
            let fields = line.split(separator: " ")
            if fields.count == 2, uid_t(fields[1]) == uid {
                found = fields[0]
                break
            }
        }
        guard let name = found, !name.contains(where: { $0 == "/" || $0 == "\0" }) else { return nil }

        let output = try await runner.run("/usr/bin/dscl", ["-plist", ".", "-read", "/Users/\(name)", "NFSHomeDirectory", "PrimaryGroupID"], timeout: timeout, maxBytes: maxBytes)
        guard output.succeeded, !output.truncated,
              let attributes = try? PropertyListDecoder().decode([String: [String]].self, from: output.stdout)
        else { throw UserDirectoryError.lookupFailed }
        // dscl은 없는 속성이 있어도 성공한다. 홈이나 그룹이 없는 계정은 사람 계정이 아니다.
        guard let home = attributes["dsAttrTypeStandard:NFSHomeDirectory"]?.first,
              let gid = attributes["dsAttrTypeStandard:PrimaryGroupID"]?.first.flatMap({ gid_t($0) }),
              home.hasPrefix("/"), !home.contains("\0")
        else { return nil }

        // 홈 경로 어디든 심볼릭 링크가 있으면 뺀다(`lstat`은 끝에 `/`가 붙은 링크를 따라간다).
        // 홈이 멈춘 볼륨에 있을 수 있어 SafeFileReader와 같은 전용 스레드에서 연다.
        let owner = try await onDedicatedThread(limited: true) { () -> uid_t? in
            let fd = unsafe open(home, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var info = stat()
            return unsafe fstat(fd, &info) == 0 ? info.st_uid : nil
        }
        guard owner == uid else { return nil }
        return UserRecord(name: String(name), uid: uid, gid: gid, home: home)
    }
}
