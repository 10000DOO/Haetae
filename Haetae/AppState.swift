import AppKit
import HaetaeShared
import Observation
import os
import ServiceManagement

enum DaemonStatus: Equatable {
    case notRegistered
    case requiresApproval
    case connecting
    case connected(build: Int)
    case verificationFailed
    case error(String)
}

@Observable
@MainActor
final class AppState {
    private static let maxRelaunches = 3
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

    private let registrar: ServiceRegistrar
    private let client: DaemonClient?
    private var isConnecting = false

    init(registrar: ServiceRegistrar, client: DaemonClient?) {
        self.registrar = registrar
        self.client = client
        needsInstall = !registrar.canRegister()
        // agent가 이미 풀렸으면 "종료할 때 끄기" 표시는 끝난 일이다.
        if !registrar.isAgentRegistered { registrar.disablesAgentOnQuit = false }
        launchAtLogin = registrar.isAgentRegistered && !registrar.disablesAgentOnQuit
    }

    func start() {
        client?.onInvalidated = { [weak self] in
            guard let self, case .connected = daemonStatus else { return }
            // 연결이 끊겼는데 "연결됨"으로 남지 않게 한다.
            daemonStatus = .connecting
            Task { await self.connect() }
        }
        Task { await connect() }
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
            quitTask = Task {
                await client?.markUserQuit()
                // 마지막에 한다. launchd가 띄운 인스턴스면 여기서 프로세스가 끝난다.
                registrar.disableAgentIfRequested()
            }
        }
        await quitTask?.value
        isReadyToTerminate = true
    }

    func connect() async {
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }

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
            daemonStatus = registerFailed ? .error("등록 실패") : .notRegistered
            return
        }
        guard let client else {
            daemonStatus = .error("팀 ID 설정 오류")
            return
        }

        daemonStatus = .connecting
        do {
            daemonStatus = .connected(build: try await client.collect().daemonBuild)
        } catch DaemonClientError.needsRelaunch {
            await relaunch()
        } catch DaemonClientError.verificationFailed {
            daemonStatus = .verificationFailed
        } catch DaemonClientError.staleDaemon {
            daemonStatus = .error("데몬이 옛 빌드")
        } catch let error as HaetaeXPCError {
            daemonStatus = .error("데몬 오류 \(error.rawValue)")
        } catch is WireValidationError {
            daemonStatus = .error("데몬 응답 형식 오류")
        } catch {
            daemonStatus = .error("데몬 응답 없음")
        }
    }

    /// 새 인스턴스를 직접 띄우지 않는다(단일 실행 규칙 때문에 둘 다 꺼진다). launchd의 재실행에 맡긴다.
    private func relaunch() async {
        guard let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) else { return }
        let key = "relaunchCount.\(build)"
        let count = UserDefaults.standard.integer(forKey: key)
        // launchd가 띄운 인스턴스가 아니면 아무도 다시 띄우지 않는다.
        guard registrar.launchedByAgent, registrar.isAgentRegistered, count < Self.maxRelaunches else {
            daemonStatus = .error("다시 실행 필요")
            return
        }
        // 횟수를 메모리에만 두면 재실행마다 0이 돼 끝없이 반복한다.
        UserDefaults.standard.set(count + 1, forKey: key)
        await client?.markUserQuit()
        exit(ServiceRegistrar.relaunchExitCode)
    }
}
