/// `NSXPCConnection.setCodeSigningRequirement`에 넘길 요구사항 문자열(3-7).
/// 순수 함수다. Debug/Release 선택(`variant`)은 호출하는 앱·데몬 타깃에서 한다.
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

    private static func requirement(identifier: String, teamID: String, minBuild: Int, variant: Variant) throws(InputError) -> String {
        // teamID는 Info.plist에서 오는 값이라 따옴표가 섞이면 요구사항이 다른 뜻으로 바뀐다. 형식이 틀리면 만들지 않는다.
        guard teamID.utf8.count == 10, teamID.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) }) else {
            throw .invalidTeamID
        }
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
