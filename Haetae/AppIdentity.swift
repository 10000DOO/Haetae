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

    static func load() -> AppIdentity? {
        // 값이 디스크의 Contents/Info.plist에서 온다. 서명된 값과 같은지까지 본다.
        let identity: SelfIdentity
        do {
            identity = try SelfIdentity.load(identifier: nil)
        } catch {
            Log.app.fault("자기 신원 확인 실패 (\(String(describing: error), privacy: .public))")
            return nil
        }
        #if DEBUG
        let variant = CodeRequirements.Variant.debug
        #else
        let variant = CodeRequirements.Variant.release
        #endif
        do {
            let app = try CodeRequirements.app(teamID: identity.teamID, minBuild: identity.minBuild, variant: variant)
            let daemon = try CodeRequirements.daemon(teamID: identity.teamID, minBuild: identity.minBuild, variant: variant)
            guard [app, daemon].allSatisfy({ CodeRequirements.compileStatus($0) == errSecSuccess }) else {
                Log.app.fault("요구사항 컴파일 실패")
                return nil
            }
            return AppIdentity(build: identity.build, appRequirement: app, daemonRequirement: daemon)
        } catch {
            Log.app.fault("요구사항 생성 실패 (\(String(describing: error), privacy: .public))")
            return nil
        }
    }
}
