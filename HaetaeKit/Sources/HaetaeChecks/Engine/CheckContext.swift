import Foundation

/// 검사 하나가 한 번 돌 때 받는 것(D17).
public struct CheckContext: Sendable {
    /// 확정된 기준값. 첫 실행이면 nil.
    public let baseline: Data?
    /// 기준값이 아직 없다 — "새로 생김"류 규칙은 건너뛰고, 기준값과 무관한 규칙은 적용한다(D7).
    public let isFirstRun: Bool
    /// 패턴 팩에서 이 검사의 구역. 없으면 빈 객체.
    public let patterns: JSONValue
    /// 호출 사용자(D29). nil이면 사용자 부분만 건너뛰고 시스템 부분은 그대로 본다.
    public let user: UserRecord?
    public let reader: SafeFileReader
    public let runner: CommandRunner
    /// 공격자가 쓸 수 있는 plist·JSON은 이것으로만 해석한다(Q42).
    public let parser: IsolatedParser
    /// 이 검사가 마지막으로 성공한 시각. 로그 검사는 이 뒤만 본다.
    public let since: Date?
}
