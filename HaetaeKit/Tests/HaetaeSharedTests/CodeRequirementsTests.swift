import Foundation
import Security
import Testing
@testable import HaetaeShared

private let teamID = "ABCDE12345"
private let minBuild = 42

// 3-7 원문을 그대로 옮기고 자리표시(<ID>, <TEAM_ID>, <MIN_BUILD>)만 채워 비교한다.
private let releaseTemplate = #"anchor apple generic and identifier "<ID>" and certificate 1[field.1.2.840.113635.100.6.2.6] and certificate leaf[field.1.2.840.113635.100.6.1.13] and certificate leaf[subject.OU] = "<TEAM_ID>" and info[CFBundleVersion] >= "<MIN_BUILD>" and entitlement["com.apple.security.get-task-allow"] absent and entitlement["com.apple.security.cs.disable-library-validation"] absent and entitlement["com.apple.security.cs.allow-dyld-environment-variables"] absent"#
private let debugTemplate = #"anchor apple generic and identifier "<ID>" and certificate leaf[subject.OU] = "<TEAM_ID>""#

enum Peer: CaseIterable, Sendable {
    case app, daemon

    var identifier: String {
        switch self {
        case .app: "com.10000DOO.Haetae"
        case .daemon: "com.10000DOO.haetaed"
        }
    }

    func requirement(teamID: String, minBuild: Int, variant: CodeRequirements.Variant) throws(CodeRequirements.InputError) -> String {
        switch self {
        case .app: try CodeRequirements.app(teamID: teamID, minBuild: minBuild, variant: variant)
        case .daemon: try CodeRequirements.daemon(teamID: teamID, minBuild: minBuild, variant: variant)
        }
    }
}

private let variants: [CodeRequirements.Variant] = [.debug, .release]

@Suite("CodeRequirements")
struct CodeRequirementsTests {
    @Test("3-7 원문과 글자 단위로 같다", arguments: Peer.allCases, variants)
    func matchesSection37(_ peer: Peer, variant: CodeRequirements.Variant) throws {
        let template = variant == .release ? releaseTemplate : debugTemplate
        let expected = template
            .replacing("<ID>", with: peer.identifier)
            .replacing("<TEAM_ID>", with: teamID)
            .replacing("<MIN_BUILD>", with: String(minBuild))
        #expect(try peer.requirement(teamID: teamID, minBuild: minBuild, variant: variant) == expected)
    }

    @Test("SecRequirementCreateWithString으로 컴파일된다", arguments: Peer.allCases, variants)
    func compiles(_ peer: Peer, variant: CodeRequirements.Variant) throws {
        for build in [0, minBuild, Int.max] {
            let text = try peer.requirement(teamID: teamID, minBuild: build, variant: variant)
            #expect(CodeRequirements.compileStatus(text) == errSecSuccess, "minBuild \(build)")
        }
    }

    @Test("Release 문자열은 디버그용 entitlement 부재와 최소 빌드를 요구한다", arguments: Peer.allCases)
    func releaseRequiresHardening(_ peer: Peer) throws {
        let text = try peer.requirement(teamID: teamID, minBuild: minBuild, variant: .release)
        #expect(text.contains(#"entitlement["com.apple.security.get-task-allow"] absent"#))
        #expect(text.contains(#"entitlement["com.apple.security.cs.disable-library-validation"] absent"#))
        #expect(text.contains(#"entitlement["com.apple.security.cs.allow-dyld-environment-variables"] absent"#))
        #expect(text.contains(#"info[CFBundleVersion] >= "42""#))
    }

    @Test("team(teamID:) 문자열이 고정 형식이고 컴파일된다")
    func teamRequirement() throws {
        let text = try CodeRequirements.team(teamID: teamID)
        #expect(text == #"anchor apple generic and certificate leaf[subject.OU] = "ABCDE12345""#)
        #expect(CodeRequirements.compileStatus(text) == errSecSuccess)
    }

    // 따옴표·개행이 들어가면 요구사항 뜻이 바뀐다. 길이는 UTF-8 바이트로 10이어도 대문자·숫자가 아니면 거부해야 한다.
    @Test("형식이 틀린 teamID는 모든 입구에서 거부한다", arguments: [
        "abcde12345", "ABCDE1234", "ABCDE123456", #"ABCD"12345"#, "ABCDE1234\n", "", "ABCDE 1234", "ÄBCDE1234", #"A" or "B12"#,
    ])
    func rejectsMalformedTeamID(_ badTeamID: String) {
        for peer in Peer.allCases {
            for variant in variants {
                #expect(throws: CodeRequirements.InputError.invalidTeamID) {
                    try peer.requirement(teamID: badTeamID, minBuild: minBuild, variant: variant)
                }
            }
        }
        #expect(throws: CodeRequirements.InputError.invalidTeamID) { try CodeRequirements.team(teamID: badTeamID) }
        #expect(throws: CodeRequirements.InputError.invalidTeamID) { try CodeRequirements.selfSignatureStatus(teamID: badTeamID, minBuild: minBuild, build: minBuild) }
    }

    @Test("음수 minBuild는 거부한다", arguments: [-1, Int.min])
    func rejectsNegativeMinBuild(_ badBuild: Int) {
        for peer in Peer.allCases {
            for variant in variants {
                #expect(throws: CodeRequirements.InputError.invalidMinBuild) {
                    try peer.requirement(teamID: teamID, minBuild: badBuild, variant: variant)
                }
            }
        }
        #expect(throws: CodeRequirements.InputError.invalidMinBuild) { try CodeRequirements.selfSignatureStatus(teamID: teamID, minBuild: badBuild, build: minBuild) }
    }

    @Test("compileStatus는 문법이 틀린 문자열에 실패를 돌려준다", arguments: [
        "", "anchor apple generic and", #"identifier "unterminated"#, "not a requirement", #"anchor apple generic and certificate leaf[subject.OU] = "A" or"#,
    ])
    func compileStatusRejectsBadSyntax(_ text: String) {
        #expect(CodeRequirements.compileStatus(text) != errSecSuccess)
    }
}
