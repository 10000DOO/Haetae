import AppKit
import os
import ServiceManagement

/// 데몬·에이전트 등록과 단일 실행. 등록할 수 없는 번들이면 등록·해제를 하나도 하지 않는다(Q33).
struct ServiceRegistrar {
    /// launchd가 띄운 인스턴스가 양보하거나 스스로 다시 뜰 때 쓰는 종료 코드.
    /// 0으로 끝내면 `KeepAlive{SuccessfulExit=false}` 조건 때문에 launchd가 다시 띄우지 않는다.
    static let relaunchExitCode: Int32 = 75
    private static let disableAgentOnQuitKey = "disableAgentOnQuit"

    private let identity: AppIdentity?
    private let daemon = SMAppService.daemon(plistName: "com.10000DOO.haetaed.plist")
    /// 사용자 파일을 해석하는 서비스(WO-49). 데몬과 함께 등록한다 — 없으면 해석이 필요한 검사가 모두 실패한다.
    private let parser = SMAppService.daemon(plistName: "com.10000DOO.haetae-parser.plist")
    private let agent = SMAppService.agent(plistName: "com.10000DOO.Haetae.agent.plist")

    init(identity: AppIdentity?) {
        self.identity = identity
    }

    /// 데몬 기준이다. 해석 서비스가 승인 대기면 같은 승인 안내를 띄운다. 없거나 등록에 실패했으면 데몬은 그대로 쓴다 —
    /// 해석이 필요한 검사만 데몬이 검사 실패로 드러낸다(WO-50). 연결까지 막으면 다른 검사도 멈춘다.
    var daemonStatus: SMAppService.Status {
        daemon.status == .enabled && parser.status == .requiresApproval ? .requiresApproval : daemon.status
    }
    /// "로그인 시 실행"의 실제 상태. 따로 저장한 값을 두지 않는다(`defaults write`로 바꿀 수 있는 값에 기대지 않는다).
    var isAgentRegistered: Bool { agent.status == .enabled }
    var agentNeedsApproval: Bool { agent.status == .requiresApproval }

    /// 누구나 붙일 수 있는 값이라 신뢰 판단에는 쓰지 않는다. 어느 쪽이 양보·재실행할지 정하는 데만 쓴다.
    var launchedByAgent: Bool { ProcessInfo.processInfo.environment["HAETAE_LAUNCHED_BY_AGENT"] != nil }

    func enforceSingleInstance() {
        let me = NSRunningApplication.current
        // 번들 ID는 누구나 흉내 낼 수 있다. 서명이 맞는 인스턴스에만 양보한다 —
        // 가짜 인스턴스에 양보하면 감시가 기록 없이 멈춘다. 판단할 수 없으면 양보하지 않는다.
        let genuineOthers = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != me && isGenuine(pid: $0.processIdentifier) }
        if !genuineOthers.isEmpty {
            exit(launchedByAgent ? Self.relaunchExitCode : 0)
        }
        // Finder에서 연 인스턴스는 launchd의 재실행 보호(D28)를 받지 못한다. agent 인스턴스가 뜨게 하고 물러난다.
        guard !launchedByAgent, canRegister() else { return }
        do {
            if agent.status == .enabled {
                try agent.unregister()
            } else if isDaemonRegistered {
                // 데몬은 등록돼 있는데 agent만 없으면 사용자가 "로그인 시 실행"을 끈 것이다.
                return
            }
            try agent.register()
        } catch {
            Log.app.error("agent 넘기기 실패 (\((error as NSError).code))")
        }
        // 승인 대기 등으로 launchd가 띄우지 않으면 이 인스턴스가 계속 돈다.
        if agent.status == .enabled { exit(0) }
    }

    /// 데몬과 해석 서비스 중 등록돼 있지 않은 것을 등록한다. 결과는 throw가 아니라 `daemonStatus`로 판단한다(승인 대기도 throw할 수 있다).
    func registerDaemonIfNeeded() throws {
        let missing = [daemon, parser].filter { $0.status == .notRegistered || $0.status == .notFound }
        guard !missing.isEmpty, canRegister() else { return }
        // 하나가 승인 대기로 throw해도 나머지를 등록한다. 첫 오류를 돌려준다.
        var firstError: (any Error)?
        for service in missing {
            do { try service.register() } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
    }

    /// 사용자가 "로그인 시 실행"을 껐지만 아직 적용하지 않았다. agent를 바로 풀면 launchd가 실행 중인 앱을 끝내므로
    /// 다음 종료 때 푼다(Q37).
    var disablesAgentOnQuit: Bool {
        get { UserDefaults.standard.bool(forKey: Self.disableAgentOnQuitKey) }
        nonmutating set { UserDefaults.standard.set(newValue, forKey: Self.disableAgentOnQuitKey) }
    }

    func enableAgent() throws {
        guard canRegister(), agent.status != .enabled else { return }
        try agent.register()
    }

    /// 종료할 때만 부른다. launchd가 띄운 인스턴스에서 부르면 이 프로세스가 끝난다(SMAppService: 실행 중인 LaunchAgent는 죽는다).
    func disableAgentIfRequested() {
        guard disablesAgentOnQuit, agent.status == .enabled else { return }
        guard canRegister() else {
            // 등록할 수 없는 번들에서는 해제도 하지 않는다(Q33). 설정 표시와 실제가 어긋나므로 남겨 둔다.
            Log.app.error("agent 해제를 건너뜀 — 등록할 수 없는 번들")
            return
        }
        do {
            try agent.unregister()
        } catch {
            Log.app.error("agent 해제 실패 (\((error as NSError).code))")
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private var isDaemonRegistered: Bool {
        daemon.status != .notRegistered && daemon.status != .notFound
    }

    /// 사용자가 쓸 수 있는 번들에서 root 데몬을 등록하면 같은 사용자 권한의 악성코드가 번들 안 파일을 바꿀 수 있다.
    /// 시작할 때 한 번만 보지 않고 등록 직전마다 다시 본다(그사이 바꿔치기).
    func canRegister() -> Bool {
        guard let identity else { return false }
        let root = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard root.deletingLastPathComponent().path == "/Applications" else { return false }
        // 읽지 못한 폴더를 건너뛰고 통과시키지 않는다.
        var enumerationFailed = false
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, errorHandler: { _, _ in
            enumerationFailed = true
            return false
        }) else { return false }
        var paths = [root.path]
        for case let url as URL in enumerator { paths.append(url.path) }
        guard !enumerationFailed else { return false }
        // 번들 안 모든 항목이 uid 0이고 그룹·기타 쓰기 비트와 ACL이 없어야 한다. 링크는 따라가지 않는다.
        let ownedByRoot = paths.allSatisfy { path in
            var info = stat()
            guard unsafe lstat(path, &info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0 else { return false }
            // ACL이 없으면 NULL + ENOENT다. 다른 오류는 "ACL 없음"으로 보지 않는다.
            guard let acl = unsafe acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
            unsafe acl_free(UnsafeMutableRawPointer(acl))
            return false
        }
        return ownedByRoot && Self.staticSignatureIsValid(root, requirement: identity.teamRequirement)
    }

    /// 추가된 파일, 번들 밖을 가리키는 링크(`kSecCSRestrictSymlinks`), 바뀐 중첩 코드(데몬)를 잡는다.
    private static func staticSignatureIsValid(_ bundle: URL, requirement: String) -> Bool {
        var code: SecStaticCode?
        var compiled: SecRequirement?
        guard unsafe SecStaticCodeCreateWithPath(bundle as CFURL, [], &code) == errSecSuccess, let code,
              unsafe SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess, let compiled else {
            return false
        }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode | kSecCSCheckAllArchitectures | kSecCSRestrictSymlinks)
        return SecStaticCodeCheckValidity(code, flags, compiled) == errSecSuccess
    }

    private func isGenuine(pid: pid_t) -> Bool {
        guard let identity else { return false }
        var code: SecCode?
        var compiled: SecRequirement?
        let attributes = [kSecGuestAttributePid as String: pid] as CFDictionary
        guard unsafe SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              unsafe SecRequirementCreateWithString(identity.appRequirement as CFString, [], &compiled) == errSecSuccess, let compiled else {
            return false
        }
        return SecCodeCheckValidity(code, [], compiled) == errSecSuccess
    }
}
