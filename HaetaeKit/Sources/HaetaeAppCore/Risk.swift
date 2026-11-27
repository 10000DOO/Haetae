import Foundation
import HaetaeShared

/// 판정을 마친 탐지 하나(패널 기록의 한 줄). 원본 기록은 데몬 원장에 있고, 이것은 보기용 캐시다(D12).
public struct Risk: Codable, Sendable, Equatable {
    public enum JudgedBy: String, Codable, Sendable {
        case llm, rule
        /// 데몬 요약으로 되살린 것(증거 없음, Q69). 다시 판정하지 않는다 — 증거 없이 수준을 낮추지 못하게(Q61과 같은 취지).
        case restored
    }

    /// 이유 칸의 상한(Unicode scalar). 파일에서 읽을 때도 본다.
    public static let maxReasonChars = 500

    public var finding: Finding
    public var level: RiskLevel
    /// 패널에만 보인다. 알림 본문에는 넣지 않는다(D12).
    public var reason: String
    public var judgedBy: JudgedBy
    public var judgedAt: Date
    /// 위험으로 볼지. 낮음이나 LLM이 낮춘 것도 기록에는 남는다(D10). 지금은 늘 `level != .low`이지만, WO-22가 수준과 따로 정할 수
    /// 있어 저장한다.
    public var isRisk: Bool
    /// 해결된 시각. nil이면 아직 있다.
    public var resolvedAt: Date?

    public init(finding: Finding, level: RiskLevel, reason: String, judgedBy: JudgedBy, judgedAt: Date, isRisk: Bool, resolvedAt: Date? = nil) {
        self.finding = finding
        self.level = level
        self.reason = reason
        self.judgedBy = judgedBy
        self.judgedAt = judgedAt
        self.isRisk = isRisk
        self.resolvedAt = resolvedAt
    }

    public var fingerprint: String { finding.fingerprint }
}
