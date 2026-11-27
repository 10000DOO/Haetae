import AppKit
import HaetaeAppCore
import SwiftUI

/// 메뉴바 아이콘(WO-14 2번). 어떤 아이콘인지는 `StatusIcon`(패키지, 시험으로 지킴)이 정하고 여기서는 그리기만 한다.
struct MenuBarIcon: View {
    let state: AppState

    var body: some View {
        let icon = self.icon
        Group {
            if icon.red {
                // 메뉴바 이미지는 템플릿으로 그려져 색이 빠진다 — 빨강은 템플릿이 아닌 이미지로.
                Image(nsImage: Self.redImage(icon.symbol))
            } else {
                Image(systemName: icon.symbol)
            }
        }
        .accessibilityLabel(icon.label)
    }

    private var icon: StatusIcon {
        let scan = state.scan
        let report = scan?.lastReport
        return StatusIcon(
            daemon: state.daemonStatus,
            hasRisk: scan?.risks.contains(where: \.isRisk) ?? false,
            notificationsOn: scan?.notificationsEnabled ?? true,
            paused: scan?.pausedUntil != nil,
            needsAttention: scan?.problem != nil || scan?.recordRebuilt == true || (report?.droppedFindings ?? 0) > 0 || report?.scanGap != nil
        )
    }

    private static func redImage(_ symbol: String) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = false
        return image
    }
}
