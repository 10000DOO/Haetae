import HaetaeAppCore
import SwiftUI

/// 살펴볼 것(WO-53 3번). 무엇을 띄울지는 `PanelBanner.list`(패키지)가 정한다.
struct PanelBanners: View {
    let banners: [PanelBanner]
    let onAction: (PanelBanner.Action) -> Void

    var body: some View {
        if !banners.isEmpty {
            VStack(spacing: 6) {
                ForEach(banners) { banner in
                    row(banner)
                }
            }
        }
    }

    private func row(_ banner: PanelBanner) -> some View {
        let color: Color = banner.high ? .red : .orange
        let textColor = banner.high ? StatusColor.dangerText : StatusColor.warningText
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: banner.symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Group {
                if banner.verbatim { Text(verbatim: banner.text) } else { Text(banner.text) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            if let action = banner.action {
                Button { onAction(action) } label: {
                    Text(action.title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(textColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(color.opacity(0.18), in: .capsule)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .card(tint: color, strength: 0.12)
    }
}
