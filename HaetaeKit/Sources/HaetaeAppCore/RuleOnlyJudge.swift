import Foundation
import HaetaeShared

/// 규칙 수준을 그대로 쓰는 판정(모델이 없거나 LLM이 실패했을 때, D10). 낮음은 기록만 하고 위험으로 보지 않는다.
public struct RuleOnlyJudge: RiskJudge {
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    public func judge(_ findings: [Finding]) async -> [Risk] {
        let at = now()
        return findings.map { Self.risk(for: $0, at: at) }
    }

    /// 파이프라인이 다른 판정의 빠진 건을 채울 때도 쓴다.
    static func risk(for finding: Finding, at: Date) -> Risk {
        Risk(finding: finding, level: finding.ruleLevel, reason: reason(checkID: finding.checkID), judgedBy: .rule, judgedAt: at, isRisk: finding.ruleLevel != .low)
    }

    /// 고정 문구 + 검사 ID만 넣는다 — 탐지 내용(공격자가 쓸 수 있는 글)은 넣지 않는다.
    static func reason(checkID: String) -> String {
        "규칙으로 판정했어요 (검사: \(checkID))"
    }
}
