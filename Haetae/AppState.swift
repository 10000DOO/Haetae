import AppKit
import HaetaeAppCore
import HaetaeShared
import Observation
import os
import ServiceManagement

/// 데몬 수명(등록·승인·핸드오프·재실행·종료)과 연결 상태. 검사 쪽 상태와 조작은 `ScanController`(`scan`)가 맡는다.
@Observable
@MainActor
final class AppState {
    private static let approvalPollInterval: Duration = .seconds(3)

    private(set) var daemonStatus: DaemonStatus = .connecting
    /// 이 위치의 번들로는 데몬을 등록할 수 없다(Q33).
    let needsInstall: Bool
    private(set) var launchAtLogin: Bool
    private(set) var launchAtLoginFailed = false
    /// 로그인 항목에서 Haetae가 꺼져 있어 "로그인 시 실행"을 켤 수 없다.
    private(set) var agentNeedsApproval = false
    /// 종료 준비가 끝났다. 이때부터만 `applicationShouldTerminate`가 바로 끝낸다.
    private(set) var isReadyToTerminate = false
    private var quitTask: Task<Void, Never>?
    var isQuitting: Bool { quitTask != nil }

    /// 데몬 요구사항을 만들지 못했으면(`AppIdentity` 실패) nil — 검사하지 않는다.
    let scan: ScanController?

    private let registrar: ServiceRegistrar
    private let client: DaemonClient?

    init(registrar: ServiceRegistrar, client: DaemonClient?) {
        self.registrar = registrar
        self.client = client
        scan = client.map { ScanController(source: $0) }
        needsInstall = !registrar.canRegister()
        // agent가 이미 풀렸으면 "종료할 때 끄기" 표시는 끝난 일이다.
        if !registrar.isAgentRegistered { registrar.disablesAgentOnQuit = false }
        launchAtLogin = registrar.isAgentRegistered && !registrar.disablesAgentOnQuit
    }

    /// 검사는 데몬 승인 확인이 끝난 뒤 시작한다.
    func start() {
        scan?.onConnected = { [weak self] build in self?.daemonStatus = .connected(build: build) }
        scan?.onCollectFailure = { [weak self] error in self?.handleCollectFailure(error) }
        client?.onInvalidated = { [weak self] in
            guard let self, case .connected = daemonStatus else { return }
            // 연결이 끊겼는데 "연결됨"으로 남지 않게 한다. 다시 붙는 것은 파이프라인의 수집이 한다.
            daemonStatus = .connecting
            scan?.connectionLost()
        }
        Task { await scan?.setUp() }
        Task { await prepareDaemon() }
        // 등록할 수 없는 번들(빌드 폴더에서 연 것)은 agent와 상관없는 인스턴스라 물러나지 않는다.
        if !registrar.launchedByAgent, !needsInstall {
            Task { await handOffWhenAgentStarts() }
        }
    }

    /// Finder에서 연 인스턴스가 떠 있는 동안 agent가 켜지면(시스템 설정에서 승인) launchd가 agent 인스턴스를 띄운다.
    /// 그 인스턴스는 이쪽을 보고 양보하기를 10초마다 되풀이하므로, 이쪽이 알아채고 물러난다.
    private func handOffWhenAgentStarts() async {
        while !(registrar.isAgentRegistered && !registrar.disablesAgentOnQuit) {
            do { try await Task.sleep(for: Self.approvalPollInterval) } catch { return }
        }
        scan?.stop()
        await client?.markUserQuit()
        exit(0)
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        Task {
            // 끄기는 표시만 해 두고 종료할 때 적용한다(Q37).
            registrar.disablesAgentOnQuit = !enabled
            launchAtLoginFailed = false
            if enabled, !registrar.isAgentRegistered {
                do {
                    try registrar.enableAgent()
                    // launchd가 방금 띄운 agent 인스턴스가 이 인스턴스를 보고 양보하기를 되풀이하지 않게 이쪽이 물러난다.
                    if registrar.isAgentRegistered, !registrar.launchedByAgent {
                        scan?.stop()
                        await client?.markUserQuit()
                        exit(0)
                    }
                } catch {
                    Log.app.error("로그인 시 실행 설정 실패 (\((error as NSError).code))")
                    launchAtLoginFailed = true
                }
            }
            launchAtLogin = registrar.isAgentRegistered && !registrar.disablesAgentOnQuit
            agentNeedsApproval = enabled && registrar.agentNeedsApproval
        }
    }

    func openLoginItemsSettings() {
        registrar.openLoginItemsSettings()
    }

    /// 메뉴 "종료"와 Cmd+Q. exit 0이라 launchd가 다시 띄우지 않는다(R13).
    func quit() {
        Task {
            await prepareToQuit()
            NSApp.terminate(nil)
        }
    }

    /// 사용자가 끄는 것이라고 데몬에 알리고, 미뤄 둔 "로그인 시 실행" 끄기를 적용한다.
    /// 한 번만 돈다. 겹친 종료 요청은 같은 작업이 끝나기를 기다린다.
    func prepareToQuit() async {
        if quitTask == nil {
            // 알린 뒤에 새 검사가 다시 연결하면 데몬이 그 연결을 비정상 종료로 적는다.
            scan?.stop()
            quitTask = Task {
                await client?.markUserQuit()
                // 마지막에 한다. launchd가 띄운 인스턴스면 여기서 프로세스가 끝난다.
                registrar.disableAgentIfRequested()
            }
        }
        await quitTask?.value
        isReadyToTerminate = true
    }

    /// 데몬을 등록하고 승인을 기다린 뒤 검사를 시작한다. 첫 검사가 곧 연결 확인이다.
    private func prepareDaemon() async {
        var registerFailed = false
        do {
            try registrar.registerDaemonIfNeeded()
        } catch {
            // 승인 대기도 오류로 올 수 있다. 결과는 아래 status로 판단한다.
            Log.app.error("데몬 등록 오류 (\((error as NSError).code))")
            registerFailed = true
        }
        // 승인은 시스템 설정에서 일어나고 앱에 알려 주지 않는다. 승인될 때까지 다시 본다.
        while registrar.daemonStatus == .requiresApproval {
            daemonStatus = .requiresApproval
            // 취소를 삼키면 이 루프가 쉬지 않고 돈다.
            do { try await Task.sleep(for: Self.approvalPollInterval) } catch { return }
        }
        guard registrar.daemonStatus == .enabled else {
            daemonStatus = registerFailed ? .registrationFailed : .notRegistered
            return
        }
        guard let scan else {
            daemonStatus = .identityError
            return
        }
        daemonStatus = .connecting
        scan.start()
    }

    private func handleCollectFailure(_ error: any Error) {
        switch CollectFailureAction(error) {
        case .relaunch: Task { await relaunch() }
        case .ignore: break
        case .show(let status): daemonStatus = status
        }
    }

    /// 새 인스턴스를 직접 띄우지 않는다(단일 실행 규칙 때문에 둘 다 꺼진다). launchd의 재실행에 맡긴다.
    private func relaunch() async {
        // 사용자가 끄는 중이면 다시 띄우지 않는다(R13).
        guard !isQuitting, let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) else { return }
        let key = "relaunchCount.\(build)"
        let count = UserDefaults.standard.integer(forKey: key)
        guard ReconnectPolicy.mayRelaunch(launchedByAgent: registrar.launchedByAgent, agentRegistered: registrar.isAgentRegistered, relaunchCount: count) else {
            daemonStatus = .relaunchNeeded
            return
        }
        UserDefaults.standard.set(count + 1, forKey: key)
        scan?.stop()
        await client?.markUserQuit()
        exit(ServiceRegistrar.relaunchExitCode)
    }
}
