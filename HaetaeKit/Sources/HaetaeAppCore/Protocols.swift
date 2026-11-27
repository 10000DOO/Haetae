import Foundation
import HaetaeShared

/// 데몬에서 검사 결과를 가져오고, 받아서 저장한 것을 알린다(D19 — 구현은 앱의 `DaemonClient`). 쓰는 쪽(파이프라인)에 필요한 것만 둔다.
/// 구현은 호출마다 시간 상한을 둔다 — 끝나지 않으면 파이프라인과 스케줄러가 함께 멈춘다.
public protocol FindingSource: Sendable {
    func collect() async throws -> CollectResult
    /// 저장을 마친 뒤에만 부른다(D24). 탐지가 0건이어도 빈 목록으로 부른다 — 데몬은 이것으로 검사 공백 표시를 지운다(Q67).
    func ack(_ fingerprints: [String]) async throws
}

/// 패턴 팩을 데몬에 넣는다(D23 — WO-41). `FindingSource`와 쓰는 쪽이 달라 나눈다(ISP).
public protocol PatternInstaller: Sendable {
    func installPatterns(_ pack: Data, signature: Data) async throws
}

/// 새 탐지를 위험으로 판정한다. 구현은 `RuleOnlyJudge`(규칙)와 LLM 판정(WO-22). 판정은 실패하지 않는다 — LLM이 실패하면 구현이
/// 규칙 판정으로 넘긴다(D10).
/// 구현은 시간 상한을 둔다(넘으면 규칙 판정으로) — 끝나지 않으면 파이프라인과 스케줄러가 함께 멈춘다.
public protocol RiskJudge: Sendable {
    /// 받은 탐지마다 하나씩, 같은 지문으로 돌려준다.
    func judge(_ findings: [Finding]) async -> [Risk]
}
