import Foundation
import HaetaeShared
import os

enum Log {
    static let app = Logger(subsystem: CodeRequirements.appIdentifier, category: "app")
}

/// 시작할 때 한 번 만든다. 만들지 못하면 데몬에 연결하지 않고 다른 인스턴스에 양보하지도 않는다(fail-closed).
struct AppIdentity {
    let build: Int
    /// 다른 Haetae 인스턴스가 진짜인지 볼 때 쓴다.
    let appRequirement: String
    let daemonRequirement: String
    /// 등록 전에 번들의 정적 서명을 볼 때 쓴다.
    let teamRequirement: String

    static func load() -> AppIdentity? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let build = (info["CFBundleVersion"] as? String).flatMap(Int.init),
              let teamID = info["HaetaeTeamID"] as? String,
              let minBuild = (info["HaetaeMinBuild"] as? String).flatMap(Int.init) else {
            Log.app.fault("Info.plist에서 빌드·팀 ID를 읽지 못함")
            return nil
        }
        #if DEBUG
        let variant = CodeRequirements.Variant.debug
        #else
        let variant = CodeRequirements.Variant.release
        #endif
        do {
            // 값이 디스크의 Contents/Info.plist에서 온다. 서명된 값과 같은지부터 본다.
            let selfStatus = try CodeRequirements.selfSignatureStatus(teamID: teamID, minBuild: minBuild)
            guard selfStatus == errSecSuccess else {
                Log.app.fault("Info.plist 값이 서명과 맞지 않음 (\(selfStatus))")
                return nil
            }
            let app = try CodeRequirements.app(teamID: teamID, minBuild: minBuild, variant: variant)
            let daemon = try CodeRequirements.daemon(teamID: teamID, minBuild: minBuild, variant: variant)
            let team = try CodeRequirements.team(teamID: teamID)
            guard [app, daemon, team].allSatisfy({ CodeRequirements.compileStatus($0) == errSecSuccess }) else {
                Log.app.fault("요구사항 컴파일 실패")
                return nil
            }
            return AppIdentity(build: build, appRequirement: app, daemonRequirement: daemon, teamRequirement: team)
        } catch {
            Log.app.fault("요구사항 생성 실패 (\(String(describing: error), privacy: .public))")
            return nil
        }
    }
}
