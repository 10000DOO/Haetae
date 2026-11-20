import Foundation
import HaetaeShared
import os
import Security

enum Log {
    static let listener = Logger(subsystem: CodeRequirements.daemonIdentifier, category: "listener")
    static let service = Logger(subsystem: CodeRequirements.daemonIdentifier, category: "service")
}

/// 데몬 시작 때 한 번 만든다. `appRequirement`가 nil이면 모든 연결을 거부한다(fail-closed).
struct DaemonConfiguration: Sendable {
    let appRequirement: String?
    let build: Int

    static func load() -> DaemonConfiguration {
        let info = Bundle.main.infoDictionary ?? [:]
        // 실행 파일에 내장된 __info_plist(서명에 묶여 있음)여야 한다. 내장 plist가 없으면 CFBundle이 Haetae.app의
        // Contents/Info.plist를 대신 돌려주므로, 식별자로 자기 것인지 확인한다.
        guard info["CFBundleIdentifier"] as? String == CodeRequirements.daemonIdentifier,
              let build = (info["CFBundleVersion"] as? String).flatMap(Int.init), build >= 0,
              let teamID = info["HaetaeTeamID"] as? String,
              let minBuild = (info["HaetaeMinBuild"] as? String).flatMap(Int.init) else {
            Log.listener.fault("내장 Info.plist를 읽지 못함 — 모든 연결 거부")
            return DaemonConfiguration(appRequirement: nil, build: 0)
        }
        #if DEBUG
        let variant = CodeRequirements.Variant.debug
        #else
        let variant = CodeRequirements.Variant.release
        #endif
        do {
            let requirement = try CodeRequirements.app(teamID: teamID, minBuild: minBuild, variant: variant)
            // NSXPC는 문법이 틀린 요구사항 문자열을 받으면 예외로 프로세스를 죽인다. 먼저 컴파일해 본다.
            var compiled: SecRequirement?
            let compileStatus = SecRequirementCreateWithString(requirement as CFString, [], &compiled)
            guard compileStatus == errSecSuccess else {
                Log.listener.fault("앱 요구사항 컴파일 실패 (\(compileStatus)) — 모든 연결 거부")
                return DaemonConfiguration(appRequirement: nil, build: build)
            }
            let selfStatus = try checkSelf(against: CodeRequirements.team(teamID: teamID))
            guard selfStatus == errSecSuccess else {
                Log.listener.fault("자기 서명이 HaetaeTeamID와 맞지 않음 (\(selfStatus)) — 모든 연결 거부")
                return DaemonConfiguration(appRequirement: nil, build: build)
            }
            return DaemonConfiguration(appRequirement: requirement, build: build)
        } catch {
            Log.listener.fault("앱 요구사항 생성 실패 (\(String(describing: error), privacy: .public)) — 모든 연결 거부")
            return DaemonConfiguration(appRequirement: nil, build: build)
        }
    }

    /// 읽은 팀 ID가 진짜 자기 팀인지 자기 서명에 대조한다. 설정 실수를 잡는 장치다(번들 변조 탐지는 D20 자기 무결성 검사가 맡는다).
    private static func checkSelf(against requirementText: String) -> OSStatus {
        var me: SecCode?
        var requirement: SecRequirement?
        var status = SecCodeCopySelf([], &me)
        guard status == errSecSuccess, let me else { return status }
        status = SecRequirementCreateWithString(requirementText as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else { return status }
        return SecCodeCheckValidity(me, [], requirement)
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate, Sendable {
    /// 마지막 연결이 끊긴 뒤 종료하기 전에 기다리는 시간(D15).
    private static let idleGrace: DispatchTimeInterval = .seconds(5)

    private struct State {
        var connections = 0
        var invalidAttempts = 0
        /// 연결이 들어오거나 종료 확인을 새로 걸 때마다 올린다. 그 전에 건 확인은 무효가 된다.
        var idleGeneration = 0
    }

    private let configuration: DaemonConfiguration
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(configuration: DaemonConfiguration) {
        self.configuration = configuration
        super.init()
        // 연결이 거부되기만 하면 연결 수가 0에서 움직이지 않는다. 시작할 때도 한 번 걸어 둔다.
        scheduleIdleCheck()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard let requirement = configuration.appRequirement else {
            Log.listener.error("요구사항 없음 — 연결 거부")
            return false
        }
        // 메시지마다 다시 검사되므로 연결 도중 상대가 바뀌어도 끊긴다(3-7). resume 전에 걸어야 한다.
        newConnection.setCodeSigningRequirement(requirement)

        let service = CollectService(callerUID: newConnection.effectiveUserIdentifier, build: configuration.build)
        newConnection.exportedInterface = NSXPCInterface(with: HaetaeXPCProtocol.self)
        newConnection.exportedObject = service
        newConnection.invalidationHandler = { [self] in
            connectionClosed(hadValidCall: service.hadValidCall)
        }

        // resume 뒤에 올리면 바로 무효화된 연결이 먼저 줄여서 수가 어긋난다.
        state.withLock {
            $0.connections += 1
            $0.idleGeneration &+= 1
        }
        newConnection.resume()
        return true
    }

    private func connectionClosed(hadValidCall: Bool) {
        let (remaining, invalidAttempts) = state.withLock { state in
            state.connections -= 1
            if !hadValidCall { state.invalidAttempts += 1 }
            return (state.connections, state.invalidAttempts)
        }
        // 서명 요구사항에 걸린 상대는 메시지가 하나도 닿지 않고 끊긴다. 누구나 반복할 수 있으니
        // 1, 2, 4, 8…번째만 남겨 로그가 불어나지 않게 한다.
        if !hadValidCall, invalidAttempts.nonzeroBitCount == 1 {
            Log.listener.error("유효한 호출 없이 끊긴 연결 (누적 \(invalidAttempts))")
        }
        if remaining == 0 { scheduleIdleCheck() }
    }

    private func scheduleIdleCheck() {
        let generation = state.withLock {
            $0.idleGeneration &+= 1
            return $0.idleGeneration
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.idleGrace) { [self] in
            if state.withLock({ $0.connections == 0 && $0.idleGeneration == generation }) {
                Log.listener.info("연결 0개 — 종료")
                exit(0)
            }
        }
    }
}
