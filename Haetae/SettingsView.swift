import SwiftUI

struct SettingsView: View {
    let state: AppState

    /// 5~60분(`AppSettings.intervalRange`) 안에서 고른다.
    private static let intervalMinutes = [5, 10, 15, 30, 60]

    var body: some View {
        Form {
            if let scan = state.scan {
                // 바꾸면 스케줄러가 바로 다음 검사 시각을 다시 정한다(WO-13 4번).
                Picker("검사 주기", selection: Binding(
                    get: { Int(scan.scanInterval.components.seconds / 60) },
                    set: { scan.setScanInterval(.seconds($0 * 60)) }
                )) {
                    // 밖에서 목록에 없는 값(범위 안)을 넣어 두었으면 그 값도 보인다 — 빈칸으로 보이지 않게.
                    let current = Int(scan.scanInterval.components.seconds / 60)
                    ForEach(Set(Self.intervalMinutes + [current]).sorted(), id: \.self) { Text("\($0)분").tag($0) }
                }
            }
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
