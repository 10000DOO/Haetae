import Foundation
import Security

/// `NSXPCConnection.setCodeSigningRequirement`에 넘길 요구사항 문자열(3-7).
/// 문자열을 만드는 함수는 순수 함수다. Debug/Release 선택(`variant`)은 호출하는 앱·데몬 타깃에서 한다.
public enum CodeRequirements {
    public enum Variant: Sendable {
        case debug, release
    }

    public enum InputError: Error, Equatable {
        case invalidTeamID
        case invalidMinBuild
    }

    public static let appIdentifier = "com.10000DOO.Haetae"
    public static let daemonIdentifier = "com.10000DOO.haetaed"

    /// 실패하면 호출한 쪽은 연결하지 않아야 한다. 요구사항 없이 `resume()`하면 아무 프로세스나 붙는다.
    public static func app(teamID: String, minBuild: Int, variant: Variant) throws(InputError) -> String {
        try requirement(identifier: appIdentifier, teamID: teamID, minBuild: minBuild, variant: variant)
    }

    public static func daemon(teamID: String, minBuild: Int, variant: Variant) throws(InputError) -> String {
        try requirement(identifier: daemonIdentifier, teamID: teamID, minBuild: minBuild, variant: variant)
    }

    /// 앱·데몬이 Info.plist에서 읽은 팀 ID를 자기 서명에 대조할 때 쓴다(`SecCodeCheckValidity`).
    public static func team(teamID: String) throws(InputError) -> String {
        try validate(teamID: teamID)
        return #"anchor apple generic and certificate leaf[subject.OU] = "\#(teamID)""#
    }

    /// NSXPC는 문법이 틀린 요구사항 문자열을 받으면 예외로 프로세스를 죽인다. 연결에 걸기 전에 컴파일해 본다.
    public static func compileStatus(_ requirement: String) -> OSStatus {
        var compiled: SecRequirement?
        return unsafe SecRequirementCreateWithString(requirement as CFString, [], &compiled)
    }

    /// Info.plist에서 읽은 팀 ID·최소 빌드가 서명된 값과 같은지 실행 중인 자기 서명에 대조한다.
    /// 읽은 뒤 파일을 되돌려 놓는 바꿔치기도 여기서 걸린다(읽은 값 = 서명된 값). 번들 변조 탐지는 D20 자기 무결성 검사가 맡는다.
    public static func selfSignatureStatus(teamID: String, minBuild: Int) throws(InputError) -> OSStatus {
        guard minBuild >= 0 else { throw .invalidMinBuild }
        let text = try team(teamID: teamID) + #" and info[HaetaeMinBuild] = "\#(minBuild)""#
        var me: SecCode?
        var requirement: SecRequirement?
        var status = unsafe SecCodeCopySelf([], &me)
        guard status == errSecSuccess, let me else { return status }
        status = unsafe SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else { return status }
        return SecCodeCheckValidity(me, [], requirement)
    }

    // teamID는 Info.plist에서 오는 값이라 따옴표가 섞이면 요구사항이 다른 뜻으로 바뀐다. 형식이 틀리면 만들지 않는다.
    private static func validate(teamID: String) throws(InputError) {
        guard teamID.utf8.count == 10, teamID.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) }) else {
            throw .invalidTeamID
        }
    }

    private static func requirement(identifier: String, teamID: String, minBuild: Int, variant: Variant) throws(InputError) -> String {
        try validate(teamID: teamID)
        guard minBuild >= 0 else { throw .invalidMinBuild }

        let base = #"anchor apple generic and identifier "\#(identifier)""#
        let team = #"certificate leaf[subject.OU] = "\#(teamID)""#
        switch variant {
        case .debug:
            return "\(base) and \(team)"
        case .release:
            return base
                + " and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13]"
                + " and \(team)"
                + #" and info[CFBundleVersion] >= "\#(minBuild)""#
                + #" and entitlement["com.apple.security.get-task-allow"] absent"#
                + #" and entitlement["com.apple.security.cs.disable-library-validation"] absent"#
                + #" and entitlement["com.apple.security.cs.allow-dyld-environment-variables"] absent"#
        }
    }
}
