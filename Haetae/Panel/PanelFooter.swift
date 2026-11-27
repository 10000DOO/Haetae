import SwiftUI

/// 아래(WO-53 6번): 주 버튼 "지금 검사" 하나, 일시정지·재개 아이콘, "…" 메뉴(설정·종료), 작은 글씨 한 줄(Q74 1번).
struct PanelFooter: View {
    let canScan: Bool
    let paused: Bool
    let caption: String?
    let onScan: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onSettings: () -> Void
    let onQuit: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                if canScan {
                    Button(action: onScan) {
                        // 검사 중이어도 눌러도 된다(스케줄러가 합친다). 검사 중 표시는 `NextScanView`가 한다.
                        Label("지금 검사", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(BrandButtonStyle())
                    .keyboardShortcut("r")
                    Button(action: paused ? onResume : onPause) {
                        Image(systemName: paused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(IconButtonStyle())
                    .help(paused ? "다시 시작" : "1시간 쉬기")
                    .accessibilityLabel(paused ? "다시 시작" : "1시간 쉬기")
                } else {
                    Spacer()
                }
                Menu {
                    Button("설정…", action: onSettings).keyboardShortcut(",")
                    Divider()
                    Button("Haetae 종료", action: onQuit).keyboardShortcut("q")
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .buttonStyle(IconButtonStyle())
                .fixedSize()
                .accessibilityLabel("더 보기")
            }
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }
}
