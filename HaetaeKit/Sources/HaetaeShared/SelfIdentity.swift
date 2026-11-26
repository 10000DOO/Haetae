import Foundation
import Security

/// 실행 중인 자기 자신의 신원(앱·데몬·해석 서비스 공통). Info.plist에서 읽은 값(빌드 포함)이 자기 서명과 맞을 때만 만든다 —
/// 읽은 뒤 파일을 되돌려 놓는 바꿔치기도 서명 대조에서 걸린다. 요구사항 문자열은 각자 필요한 것만 `CodeRequirements`로 만든다.
public struct SelfIdentity: Sendable, Equatable {
    public let build: Int
    public let teamID: String
    public let minBuild: Int

    public enum LoadError: Error, Equatable {
        /// 빌드·팀 ID·최소 빌드 중 하나가 없거나 숫자가 아니다.
        case missingInfo
        /// 내장 Info.plist가 없어 CFBundle이 다른 번들(앱)의 것을 돌려줬다.
        case wrongIdentifier
        case invalidInput(CodeRequirements.InputError)
        /// Info.plist 값이 자기 서명과 맞지 않는다.
        case signatureMismatch(OSStatus)
    }

    /// - Parameters:
    ///   - identifier: 데몬·해석 서비스처럼 실행 파일에 내장된 `__info_plist`를 읽는 쪽은 자기 식별자를 넘긴다 — 내장 plist가 없으면
    ///     CFBundle이 Haetae.app의 Contents/Info.plist를 대신 돌려주기 때문이다. 앱은 nil(디스크의 Info.plist가 자기 것).
    ///   - info: 테스트에서 주입한다.
    public static func load(identifier: String?, info: [String: Any]? = Bundle.main.infoDictionary) throws(LoadError) -> SelfIdentity {
        let info = info ?? [:]
        if let identifier, info["CFBundleIdentifier"] as? String != identifier { throw .wrongIdentifier }
        guard let build = (info["CFBundleVersion"] as? String).flatMap(Int.init), build >= 0,
              let teamID = info["HaetaeTeamID"] as? String,
              let minBuild = (info["HaetaeMinBuild"] as? String).flatMap(Int.init) else { throw .missingInfo }
        let status: OSStatus
        do {
            status = try CodeRequirements.selfSignatureStatus(teamID: teamID, minBuild: minBuild, build: build)
        } catch {
            throw .invalidInput(error)
        }
        guard status == errSecSuccess else { throw .signatureMismatch(status) }
        return SelfIdentity(build: build, teamID: teamID, minBuild: minBuild)
    }
}
