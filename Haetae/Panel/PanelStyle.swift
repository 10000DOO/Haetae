import AppKit
import HaetaeAppCore
import HaetaeShared
import SwiftUI

/// 브랜드 색(Q79 — 미드나이트 인디고 + 민트). 강조(머리 원·주 버튼·진행 막대)에만 쓰고 상태 색(빨강·주황)과 섞지 않는다.
/// 에셋이 아니라 코드로 둔다 — 저장소 밖에서 같은 파일로 화면을 그려 볼 때도 같은 색이 나오게(WO-53 완료 판정).
enum Brand {
    static let indigo = dynamic(light: 0x26215C, dark: 0x3C3489)
    static let primary = dynamic(light: 0x534AB7, dark: 0x5E55C6)
    static let mint = dynamic(light: 0x3FB68E, dark: 0x5DCAA5)

    /// 밝은·어두운 모드에 따라 바뀌는 색. 색 공급 클로저는 AppKit이 아무 스레드에서나 부를 수 있어 격리 밖에서 만든다.
    nonisolated static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1
            )
        })
    }
}

/// 작은 글에 쓰는 상태 색. 시스템 주황·빨강은 흰 바탕에서 작은 글 기준(4.5:1)에 못 미쳐 한 단계 진하게 둔다(설계 리뷰 L3).
enum StatusColor {
    static let dangerText = Brand.dynamic(light: 0xB3261E, dark: 0xFF8A80)
    static let warningText = Brand.dynamic(light: 0x9A4A00, dark: 0xFFB45C)
}

extension PanelHeadline.Tone {
    /// 글·기호 색.
    var color: Color {
        switch self {
        case .brand: Brand.mint
        case .danger: .red
        case .warning: .orange
        case .neutral: .secondary
        }
    }
}

extension RiskLevel {
    var label: String {
        switch self {
        case .high: "높음"
        case .medium: "중간"
        case .low: "낮음"
        }
    }

    var color: Color {
        switch self {
        case .high: .red
        case .medium: .orange
        case .low: .secondary
        }
    }

    /// 배지 글자 색(작은 글 — 대비를 맞춘 진한 색).
    var textColor: Color {
        switch self {
        case .high: StatusColor.dangerText
        case .medium: StatusColor.warningText
        case .low: .secondary
        }
    }
}

/// 패널의 주 버튼(하나만 — "지금 검사").
struct BrandButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(Brand.primary.opacity(configuration.isPressed ? 0.75 : 1), in: .rect(cornerRadius: 8))
            .contentShape(.rect(cornerRadius: 8))
    }
}

/// 아이콘만 있는 보조 버튼. 마우스를 올리면 바탕이 드러난다.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration)
    }

    private struct IconButtonBody: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.body.weight(.semibold))
                // 기호는 진하게 — 흐리면 꺼진 버튼처럼 보인다(2026-11-27 사용자 화면 확인).
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
                .background(.primary.opacity(configuration.isPressed ? 0.22 : hovering ? 0.16 : 0.10), in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.12)))
                .contentShape(.rect(cornerRadius: 8))
                .onHover { hovering = $0 }
        }
    }
}

/// 옅은 바탕 카드(다음 검사, 배너, 증거). 테두리를 둬 어두운 재질 바탕에서도 칸이 구분되게 한다(2026-11-27 사용자 화면 확인).
struct CardBackground: ViewModifier {
    var tint: Color = .primary
    var strength = 0.08

    func body(content: Content) -> some View {
        content
            .background(tint.opacity(strength), in: .rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.12)))
    }
}

extension View {
    func card(tint: Color = .primary, strength: Double = 0.08) -> some View {
        modifier(CardBackground(tint: tint, strength: strength))
    }
}
