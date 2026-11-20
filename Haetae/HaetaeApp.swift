import os
import SwiftUI

/// 패널 "종료" 말고도 앱이 꺼지는 길이 있다(Cmd+Q, 로그아웃, 다른 프로세스가 보낸 quit). 길마다 다르게 끝낸다(Q38).
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var state: AppState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = Self.state, !state.isReadyToTerminate else { return .terminateNow }
        let event = NSAppleEventManager.shared().currentAppleEvent
        guard let event, event.eventClass == AEEventClass(kCoreEventClass), event.eventID == AEEventID(kAEQuitApplication) else {
            // quit Apple Event가 아니면 Cmd+Q·메뉴·코드 호출이다: 패널 "종료"와 같게 한다.
            // .terminateLater로 기다리지 않는다 — 메인 큐 작업 안에서 불린 terminate는 준비 Task가 돌지 못해 영영 멈춘다.
            state.quit()
            return .terminateCancel
        }
        // 종료 준비가 이미 돌고 있으면 그 준비가 끝나기를 기다린다(중간에 끊으면 데몬 알림과 agent 해제가 빠진다).
        if state.isQuitting || Self.isSystemQuit(event) {
            Task {
                await state.prepareToQuit()
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        // 다른 프로세스가 보낸 quit: 0으로 끝내면 launchd가 다시 띄우지 않아 재실행 보호가 꺼진다.
        Log.app.error("외부 quit — 다시 뜨도록 끝냄")
        exit(ServiceRegistrar.relaunchExitCode)
    }

    /// 로그아웃·재시동·시스템 종료인지. 종료 사유는 보내는 쪽이 마음대로 붙일 수 있으니,
    /// 위조할 수 없는 보낸 쪽 audit token으로 loginwindow가 보냈는지까지 본다.
    private static func isSystemQuit(_ event: NSAppleEventDescriptor) -> Bool {
        guard event.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil,
              let token = event.attributeDescriptor(forKeyword: AEKeyword(keySenderAuditTokenAttr))?.data,
              token.count == MemoryLayout<audit_token_t>.size else { return false }
        var code: SecCode?
        var requirement: SecRequirement?
        let attributes = [kSecGuestAttributeAudit as String: token] as CFDictionary
        guard unsafe SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code,
              unsafe SecRequirementCreateWithString(#"anchor apple and identifier "com.apple.loginwindow""# as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }
}

@main
struct HaetaeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state: AppState

    init() {
        let identity = AppIdentity.load()
        let registrar = ServiceRegistrar(identity: identity)
        // 데몬에 첫 호출을 보내기 전에 판단한다. 호출한 뒤 양보하면 데몬이 비정상 종료로 기록한다.
        registrar.enforceSingleInstance()
        let state = AppState(registrar: registrar, client: identity.map(DaemonClient.init))
        _state = State(initialValue: state)
        AppDelegate.state = state
        state.start()
    }

    var body: some Scene {
        MenuBarExtra("Haetae", systemImage: "shield") {
            PanelView(state: state)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(state: state)
        }
    }
}
