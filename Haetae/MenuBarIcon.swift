import AppKit
import HaetaeAppCore
import SwiftUI

/// 메뉴바 아이콘(WO-14 2번). 어떤 아이콘인지는 `StatusIcon`(패키지, 시험으로 지킴)이 정하고 여기서는 그리기만 한다.
struct MenuBarIcon: View {
    let state: AppState

    var body: some View {
        let icon = self.icon
        Group {
            Image(nsImage: Self.image(icon.symbol, red: icon.red))
        }
        .accessibilityLabel(icon.label)
    }

    private var icon: StatusIcon {
        StatusIcon(state: state.watchState, hasRisk: state.scan?.risks.contains(where: \.isRisk) ?? false)
    }

    /// 기호 크기는 기본보다 조금 크게(사용자 요청 2026-11-27). 메뉴바 이미지는 템플릿으로 그려져 색이 빠진다 — 빨강은 템플릿이 아닌 이미지로.
    private static let pointSize: CGFloat = 16
    private static var cache: [String: NSImage] = [:]

    private static func image(_ symbol: String, red: Bool) -> NSImage {
        let key = "\(symbol)|\(red)"
        if let cached = cache[key] { return cached }
        var configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
        if red { configuration = configuration.applying(NSImage.SymbolConfiguration(paletteColors: [.systemRed])) }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) ?? NSImage()
        image.isTemplate = !red
        cache[key] = image
        return image
    }
}
