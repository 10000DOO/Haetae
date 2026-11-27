import HaetaeAppCore
import SwiftUI

/// 다음 검사(WO-53 2번, R4 ②): 남은 시간과 주기 대비 진행 막대. 검사 중·일시정지면 그 상태를 보인다.
struct NextScanView: View {
    enum Phase: Equatable {
        case scanning
        case paused(until: Date)
        case scheduled(at: Date, interval: TimeInterval)
        case notStarted
    }

    let phase: Phase

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .animation(.snappy, value: phase)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .scanning:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(Brand.mint)
                .symbolEffect(.rotate, options: .repeat(.continuous))
                .accessibilityHidden(true)
            Text("검사하고 있어요…")
        case .paused(let until):
            Image(systemName: "pause.circle").foregroundStyle(.secondary).accessibilityHidden(true)
            Text("\(PanelTime.clock(until))까지 쉬어요")
        case .scheduled(let at, let interval):
            Image(systemName: "clock").foregroundStyle(.secondary).accessibilityHidden(true)
            // 남은 시간은 분 단위라 분이 바뀔 때만 다시 그린다.
            TimelineView(.everyMinute) { context in
                VStack(alignment: .leading, spacing: 6) {
                    Text(label(at: at, now: context.date))
                        .monospacedDigit()
                    // 시스템 진행 막대는 창이 앞에 없으면 회색이 된다 — 브랜드 색이 늘 보이게 직접 그린다.
                    Capsule()
                        .fill(.primary.opacity(0.18))
                        .frame(height: 4)
                        .overlay(alignment: .leading) {
                            GeometryReader { proxy in
                                Capsule()
                                    .fill(Brand.mint)
                                    .frame(width: proxy.size.width * progress(at: at, interval: interval, now: context.date))
                            }
                        }
                        .accessibilityHidden(true)
                }
            }
        case .notStarted:
            Image(systemName: "clock").foregroundStyle(.secondary).accessibilityHidden(true)
            Text("첫 검사를 준비하고 있어요")
        }
    }

    private func label(at: Date, now: Date) -> String {
        let remaining = PanelTime.remaining(until: at, now: now)
        return remaining == "곧" ? "곧 검사해요" : "다음 검사까지 \(remaining)"
    }

    private func progress(at: Date, interval: TimeInterval, now: Date) -> Double {
        guard interval > 0 else { return 0 }
        return min(max(1 - at.timeIntervalSince(now) / interval, 0), 1)
    }
}
