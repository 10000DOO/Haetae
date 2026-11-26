import Foundation
import Security

/// 번들을 root만 바꿀 수 있고 서명이 온전한지(D20, Q33). 앱은 데몬을 등록하기 직전에, 데몬은 시작할 때 본다.
/// 사용자가 쓸 수 있는 번들이면 같은 사용자 권한의 악성코드가 번들 안 파일을 바꿔 root 데몬으로 돌릴 수 있다.
public enum BundleIntegrity {
    public enum Problem: Error, Equatable, Sendable {
        /// 번들 안을 다 읽지 못했다 — 읽지 못한 폴더를 건너뛰고 통과시키지 않는다.
        case unreadable
        /// 값은 번들 기준 상대 경로("."이면 번들 자신).
        case notRootOwned(String)
        case writableByOthers(String)
        case hasACL(String)
        case invalidSignature(OSStatus)
    }

    /// 번들 안 모든 항목(링크는 따라가지 않음)이 uid 0이고 그룹·기타 쓰기 비트와 ACL이 없는지 보고, 정적 서명을 strict·중첩 코드까지
    /// 확인한다(추가된 파일, 번들 밖을 가리키는 링크, 바뀐 중첩 코드). 문제가 없으면 빈 배열.
    /// 소유 문제와 서명 문제는 따로 본다 — 하나만 돌려주면 소유 문제를 확인한 뒤 서명까지 깨져도 같은 결과라 다시 알리지 못한다.
    public static func problems(in bundle: URL, requirement: String) -> [Problem] {
        [ownershipProblem(in: bundle), signatureProblem(of: bundle, requirement: requirement)].compactMap(\.self)
    }

    private static func ownershipProblem(in bundle: URL) -> Problem? {
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil, errorHandler: { _, _ in
            enumerationFailed = true
            return false
        }) else { return .unreadable }
        var urls = [bundle]
        for case let url as URL in enumerator { urls.append(url) }
        guard !enumerationFailed else { return .unreadable }

        let rootPath = bundle.path
        for url in urls {
            let path = url.path
            let relative = path == rootPath ? "." : String(path.dropFirst(rootPath.count + 1))
            var info = stat()
            guard unsafe lstat(path, &info) == 0 else { return .unreadable }
            guard info.st_uid == 0 else { return .notRootOwned(relative) }
            guard info.st_mode & 0o022 == 0 else { return .writableByOthers(relative) }
            // ACL이 없으면 NULL + ENOENT다. 다른 오류는 "ACL 없음"으로 보지 않는다.
            guard let acl = unsafe acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
                guard errno == ENOENT else { return .unreadable }
                continue
            }
            unsafe acl_free(UnsafeMutableRawPointer(acl))
            return .hasACL(relative)
        }
        return nil
    }

    private static func signatureProblem(of bundle: URL, requirement: String) -> Problem? {
        var code: SecStaticCode?
        var compiled: SecRequirement?
        var status = unsafe SecStaticCodeCreateWithPath(bundle as CFURL, [], &code)
        guard status == errSecSuccess, let code else { return .invalidSignature(status) }
        status = unsafe SecRequirementCreateWithString(requirement as CFString, [], &compiled)
        guard status == errSecSuccess, let compiled else { return .invalidSignature(status) }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures | kSecCSRestrictSymlinks)
        status = SecStaticCodeCheckValidity(code, flags, compiled)
        return status == errSecSuccess ? nil : .invalidSignature(status)
    }
}
