import SwiftUI

struct PanelView: View {
    let state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(statusText, systemImage: statusSymbol)
                .foregroundStyle(isFailure ? .red : .primary)

            if state.needsInstall {
                Text("`/Applications`에 설치한 뒤 실행하세요. 이 위치에서는 데몬을 등록하지 않습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if state.daemonStatus == .requiresApproval {
                Button("로그인 항목 설정 열기") { state.openLoginItemsSettings() }
            }

            Divider()
            HStack {
                Button("설정") {
                    // Dock 아이콘이 없는 앱이라 앞으로 가져오지 않으면 설정 창이 다른 앱 뒤에 뜬다.
                    NSApp.activate()
                    openSettings()
                }
                Spacer()
                Button("종료") { state.quit() }
            }
        }
        .padding()
        .frame(width: 300)
    }

    private var statusText: String {
        switch state.daemonStatus {
        case .notRegistered: "데몬이 등록되지 않음"
        case .requiresApproval: "시스템 설정에서 승인이 필요함"
        case .connecting: "연결 중"
        case .connected(let build): "연결됨 (빌드 \(build))"
        case .verificationFailed: "데몬 검증 실패"
        case .error(let message): message
        }
    }

    private var statusSymbol: String {
        switch state.daemonStatus {
        case .connected: "checkmark.shield"
        case .connecting: "shield"
        default: "exclamationmark.shield"
        }
    }

    private var isFailure: Bool {
        switch state.daemonStatus {
        case .verificationFailed, .error: true
        default: false
        }
    }
}
