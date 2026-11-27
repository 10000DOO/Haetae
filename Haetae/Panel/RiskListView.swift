import HaetaeAppCore
import HaetaeShared
import SwiftUI

/// 위험 목록(WO-53 4·5번). 누르면 그 자리에서 펼친다(Q75 2번). 탐지에서 온 글(제목·이유·검사 ID·증거)은 `Text(verbatim:)`로만 그린다(D12).
struct RiskListView: View {
    let risks: [Risk]
    /// 데몬 응답으로 확인한 지문. 확인 전 항목은 "확인 전"으로 보이고 증거를 숨긴다.
    let verified: Set<String>
    let lastScan: Date?

    @State private var expanded: Set<String>
    /// 증거를 끝까지 펼친 지문. 줄 안이 아니라 여기 둔다 — 목록이 스크롤 칸으로 바뀌면 줄이 새로 만들어져 줄 안 상태가 풀린다
    /// (3건 이하에서 "더 보기"가 바로 다시 접혔다, WO-55 설계 재리뷰 L1).
    @State private var showsAllEvidence: Set<String> = []
    /// 줄마다 잰 높이. 스크롤 칸 높이를 앞 3줄에 맞춘다.
    @State private var rowHeights: [String: CGFloat] = [:]

    /// 이만큼은 스크롤 없이 다 보인다(2026-11-27 사용자 — 3건까지는 한눈에, 넘으면 스크롤).
    private static let visibleRows = 3
    /// 넘칠 때 다음 줄을 조금 보여 스크롤할 것이 있다는 것을 알린다.
    private static let peek: CGFloat = 28
    /// 앞 줄을 펼쳐 증거가 길어도 패널이 화면을 넘지 않게.
    private static let maxListHeight: CGFloat = 520

    /// - Parameter expanded: 처음 한 번만 쓰는 펼침 상태(미리 보기·화면 확인용). 그 뒤로는 뷰가 갖는다.
    init(risks: [Risk], verified: Set<String>, lastScan: Date?, expanded: Set<String> = []) {
        self.risks = risks
        self.verified = verified
        self.lastScan = lastScan
        _expanded = State(initialValue: expanded)
    }

    var body: some View {
        if risks.isEmpty {
            empty
        } else {
            Group {
                if risks.count <= Self.visibleRows, totalHeight <= Self.maxListHeight {
                    rows
                } else {
                    // 메뉴바 창 안의 스크롤 칸은 스스로 높이를 잡지 못해 작게 접힌다 — 줄 높이를 재서 정해 준다. 3건 이하여도 펼친
                    // 증거가 길면 스크롤 칸으로 — 아래 버튼이 화면 밖으로 밀리지 않게(보안 재리뷰 L).
                    ScrollView { rows }
                        .scrollBounceBehavior(.basedOnSize)
                        .frame(height: scrollHeight)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
        }
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(risks, id: \.fingerprint) { risk in
                RiskRow(
                    risk: risk, verified: verified.contains(risk.fingerprint), expanded: binding(risk.fingerprint, in: \.expanded),
                    showsAllEvidence: binding(risk.fingerprint, in: \.showsAllEvidence)
                )
                    .overlay(alignment: .top) {
                        if risk.fingerprint != risks.first?.fingerprint { Divider() }
                    }
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowHeights[risk.fingerprint] = $0 }
            }
        }
    }

    /// 4건 이상이면 앞 3줄 + 다음 줄 살짝, 3건 이하면 전체(상한까지). 아직 재지 못한 줄은 접힌 한 줄 높이로 친다.
    private var scrollHeight: CGFloat {
        guard risks.count > Self.visibleRows else { return min(totalHeight, Self.maxListHeight) }
        return min(height(of: risks.prefix(Self.visibleRows)) + Self.peek, Self.maxListHeight)
    }

    private var totalHeight: CGFloat { height(of: risks[...]) }

    private func height(of rows: ArraySlice<Risk>) -> CGFloat {
        rows.reduce(0) { $0 + (rowHeights[$1.fingerprint] ?? 64) }
    }

    /// 한 번도 검사하지 못했으면 "없음"이라고 하지 않는다 — 감시가 돌지 않는데 안심하게 하지 않게(WO-14).
    private var empty: some View {
        VStack(spacing: 6) {
            Image(systemName: lastScan == nil ? "hourglass" : "checkmark.circle")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(lastScan == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(Brand.mint))
            Text(lastScan == nil ? "아직 검사하지 않았어요" : "발견된 위험이 없어요")
                .font(.body.weight(.medium))
            if let lastScan {
                Text("\(PanelTime.clock(lastScan)) 검사 기준")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .accessibilityElement(children: .combine)
    }

    private func binding(_ fingerprint: String, in set: ReferenceWritableKeyPath<Self, Set<String>>) -> Binding<Bool> {
        Binding(
            get: { self[keyPath: set].contains(fingerprint) },
            set: { isOn in
                withAnimation(.snappy) {
                    if isOn { self[keyPath: set].insert(fingerprint) } else { self[keyPath: set].remove(fingerprint) }
                }
            }
        )
    }
}

private struct RiskRow: View {
    let risk: Risk
    let verified: Bool
    @Binding var expanded: Bool
    @Binding var showsAllEvidence: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: { summary }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityText)
                .accessibilityValue(expanded ? "펼침" : "접힘")
                .accessibilityHint(expanded ? "접으려면 누르세요" : "자세히 보려면 누르세요")
            if expanded {
                RiskDetail(risk: risk, verified: verified, showsAllEvidence: $showsAllEvidence)
                    .padding(.leading, 12)
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 10) {
            LevelBadge(level: risk.level)
            VStack(alignment: .leading, spacing: 3) {
                // 접으면 가운데를 줄인다 — 앞에 긴 경로를 붙여 진짜 파일 이름(끝)을 숨기지 못하게. 펼치면 전체(보안 리뷰 L2).
                Text(verbatim: risk.finding.title)
                    .font(.body.weight(.medium))
                    .lineLimit(expanded ? nil : 2)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(verbatim: risk.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(expanded ? nil : 1)
                if !verified || !risk.isRisk {
                    HStack(spacing: 6) {
                        if !verified { Tag(text: "확인 전") }
                        if !risk.isRisk { Tag(text: "위험 아님") }
                    }
                }
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .padding(.top, 3)
                .accessibilityHidden(true)
        }
        .padding(12)
        .contentShape(.rect)
    }

    /// 탐지 글과 앱이 붙인 표시를 구분해 읽는다 — 제목이 "…위험 아님"으로 끝나도 앱 태그와 섞이지 않게(보안 리뷰 의견).
    private var accessibilityText: String {
        var parts = ["\(risk.level.label) 수준", "제목: \(risk.finding.title)", "이유: \(risk.reason)"]
        if !verified { parts.append("표시: 확인 전") }
        if !risk.isRisk { parts.append("표시: 위험 아님") }
        return parts.joined(separator: ". ")
    }
}

/// 펼친 내용: 검사 ID·발견 시각·증거. 증거는 데몬이 가린 글이다(SecretMasker). 확인 전 항목은 파일에서 읽고 아직 데몬 응답으로
/// 확인하지 못한 글이라 같은 사용자가 바꿔 둘 수 있어 보이지 않는다(WO-53 4번).
private struct RiskDetail: View {
    let risk: Risk
    let verified: Bool
    @Binding var showsAllEvidence: Bool

    private static let evidencePreviewLines = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("검사").foregroundStyle(.secondary)
                    Text(verbatim: risk.finding.checkID).font(.caption.monospaced()).textSelection(.enabled)
                }
                GridRow {
                    Text("발견").foregroundStyle(.secondary)
                    Text(PanelTime.dateTime(risk.finding.observedAt))
                }
            }
            .font(.caption)
            evidence
        }
    }

    @ViewBuilder
    private var evidence: some View {
        if !verified {
            note("확인 전이라 증거를 숨겼어요. 다음 검사에서 확인되면 보여요.")
        } else if risk.finding.evidence.isEmpty {
            note("증거는 다음 검사에서 다시 받아요.")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: risk.finding.evidence)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(showsAllEvidence ? nil : Self.evidencePreviewLines)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .card(strength: 0.06)
                if isLong {
                    Button(showsAllEvidence ? "접기" : "더 보기") { showsAllEvidence.toggle() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
    }

    /// 대강의 판단이다 — 줄 수나 길이가 미리보기를 넘을 만하면 "더 보기"를 단다.
    private var isLong: Bool {
        let evidence = risk.finding.evidence
        return evidence.count(where: { $0 == "\n" }) >= Self.evidencePreviewLines || evidence.count > 400
    }

    private func note(_ text: String) -> some View {
        Label(text, systemImage: "eye.slash")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

private struct LevelBadge: View {
    let level: RiskLevel

    var body: some View {
        Text(level.label)
            .font(.caption2.weight(.bold))
            .foregroundStyle(level.textColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(level.color.opacity(0.15), in: .capsule)
            .padding(.top, 1)
    }
}

private struct Tag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.primary.opacity(0.07), in: .capsule)
    }
}
