import HaetaeAppCore
import SwiftUI

/// 패널 머리(WO-53 1번): 원 안 상태 기호 + 결론 한 줄 + 설명·마지막 확인.
struct PanelHeader: View {
    let headline: PanelHeadline
    let lastScan: Date?

    var body: some View {
        HStack(spacing: 12) {
            badge
            VStack(alignment: .leading, spacing: 2) {
                Text(headline.title)
                    .font(.title3.weight(.semibold))
                    .fontDesign(.rounded)
                    .foregroundStyle(headline.tone == .danger ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
                // 마지막 확인은 분 단위라 분이 바뀔 때만 다시 그린다.
                TimelineView(.everyMinute) { context in
                    Text(subtitle(now: context.date))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var badge: some View {
        ZStack {
            Circle().fill(headline.tone == .brand ? AnyShapeStyle(Brand.indigo) : AnyShapeStyle(headline.tone.color.opacity(0.15)))
            if headline.tone == .brand {
                Circle().strokeBorder(Brand.mint, lineWidth: 2)
            }
            Image(systemName: headline.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(headline.tone == .brand ? AnyShapeStyle(.white) : AnyShapeStyle(headline.tone.color))
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 44, height: 44)
        .animation(.snappy, value: headline)
        .accessibilityHidden(true)
    }

    private func subtitle(now: Date) -> String {
        let checked = lastScan.map { "\(PanelTime.ago($0, now: now)) 확인" }
        return [headline.detail, checked].compactMap(\.self).joined(separator: " · ")
    }
}
