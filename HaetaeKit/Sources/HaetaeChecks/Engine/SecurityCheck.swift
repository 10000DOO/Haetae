import Foundation
import HaetaeShared

/// 감시 대상 하나(D17). 대상을 더할 때는 이 프로토콜을 구현한 파일 하나와 `CheckRegistry.all`의 한 줄만 더한다.
/// 구현 안에서 `Process`·`FileManager`를 직접 쓰지 않는다 — `CheckContext`의 `runner`·`reader`·`parser`만 쓴다.
public protocol SecurityCheck: Sendable {
    var id: String { get }
    var timeout: Duration { get }
    var needsBaseline: Bool { get }
    /// 기준값 형식이 바뀌면 올린다 — 그 검사만 다시 학습한다(D21).
    var baselineVersion: Int { get }

    func run(_ ctx: CheckContext) async throws -> CheckResult
}

public struct CheckResult: Sendable {
    /// `checkID`와 `observedAt`은 `CheckRunner`가 채운다.
    public var findings: [Finding]
    /// 중간 이상 Finding을 낸 항목은 넣지 않는다(Q51) — 그 항목이 있는 동안 계속 보고되고, 사라져야 해결로 간다.
    /// nil이면 기준값을 그대로 둔다.
    public var newBaseline: Data?
    /// 보지 못한 것이 있다(파일 해석 실패 등). 안 보인 Finding을 해결된 것으로 보내지 않는다.
    public var partial: Bool

    public init(findings: [Finding], newBaseline: Data? = nil, partial: Bool = false) {
        self.findings = findings
        self.newBaseline = newBaseline
        self.partial = partial
    }
}
