import SwiftUI

struct SettingsView: View {
    let state: AppState

    var body: some View {
        Form {
            Toggle("로그인 시 실행", isOn: Binding(
                get: { state.launchAtLogin },
                set: { state.setLaunchAtLogin($0) }
            ))
            .disabled(state.needsInstall)
            Text("끄면 Haetae를 종료할 때 적용됩니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if state.agentNeedsApproval {
                Text("시스템 설정의 로그인 항목에서 Haetae가 꺼져 있습니다.")
                    .font(.callout)
                Button("로그인 항목 설정 열기") { state.openLoginItemsSettings() }
            }
            if state.launchAtLoginFailed {
                Text("로그인 시 실행 설정 실패")
                    .foregroundStyle(.red)
            }
        }
        .padding()
        .frame(width: 320)
    }
}
