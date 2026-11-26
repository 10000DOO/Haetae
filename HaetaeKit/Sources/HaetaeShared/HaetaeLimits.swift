public enum HaetaeLimits {
    public static let maxReplyBytes = 4_000_000
    /// 길이 상한은 모두 Unicode scalar 수로 센다. `String.count`(grapheme)는 결합 문자로 바이트 수를 무한히 늘릴 수 있다.
    public static let maxEvidenceChars = 2_000
    public static let maxTitleChars = 200
    public static let maxCheckIDChars = 100
    public static let maxFindingsPerCheck = 200
    /// 한 응답의 findings 수 = ack 한 번의 지문 수. 둘이 다르면 앱이 받은 것을 한 번에 ack할 수 없다.
    public static let maxFindingsPerReply = 1_000
    public static let maxAckFingerprints = maxFindingsPerReply
    /// 지문 1개 = 64자 + 따옴표·쉼표. 여유를 둔 값.
    public static let maxAckBytes = 100_000
    public static let maxPatternPackBytes = 2_000_000
    /// 검사 한 바퀴(`CheckRunner.runAll`)의 상한. 넘으면 남은 검사는 타임아웃 실패가 된다. 앱의 `collect` 대기는 이것보다 길어야 한다.
    /// shortcut: 검사가 아직 없어 재지 못한 임시 값이다, 검사가 들어온 뒤(WO-18) 실측으로 다시 정한다.
    public static let maxRunDuration: Duration = .seconds(25)
}
