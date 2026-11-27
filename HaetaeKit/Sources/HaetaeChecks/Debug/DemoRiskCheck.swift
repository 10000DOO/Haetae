#if DEBUG
import Foundation
import HaetaeShared

/// Debug 전용 데모 검사(WO-54, Q80 2번 — 임시). 실제 검사(WO-15~18) 전에 위험이 났을 때의 화면·알림·해결 흐름을 겪어 보게 한다.
/// 호출 사용자의 `~/Library/Application Support/Haetae/demo-risks.txt`에 적은 줄마다 위험 하나를 내고, 줄을 지우면 다음 검사에서
/// 해결로 간다. Release에는 들어가지 않는다(파일 전체와 `haetaed/main.swift`의 추가가 `#if DEBUG`).
///
/// 줄 형식: `high|medium|low 제목`(또는 `높음|중간|낮음 제목`). 빈 줄과 `#`로 시작하는 줄은 건너뛴다.
public struct DemoRiskCheck: SecurityCheck {
    public let id = "debug.demo"
    public let timeout: Duration = .seconds(2)
    public let needsBaseline = false
    public let baselineVersion = 1

    static let relativePath = "Library/Application Support/Haetae/demo-risks.txt"
    static let maxBytes = 16 * 1024
    static let maxLines = 20

    public init() {}

    public func run(_ ctx: CheckContext) async throws -> CheckResult {
        guard let user = ctx.user else { return CheckResult(findings: [], partial: true) }
        let path = (user.home as NSString).appendingPathComponent(Self.relativePath)
        let data: Data
        do {
            // 사용자 권한으로만 읽는다(링크·남의 파일 거부 — D25).
            data = try await ctx.reader.read(path: path, asUser: user, maxBytes: Self.maxBytes)
        } catch SafeFileError.system(ENOENT) {
            // 파일이 없으면 위험도 없다 — 전에 낸 것은 해결로 간다.
            return CheckResult(findings: [])
        }
        let findings = Self.parse(String(decoding: data, as: UTF8.self)).map { line in
            Finding(
                checkID: id, title: line.title,
                // 줄 번호는 넣지 않는다 — 위에 줄을 더하면 같은 지문의 증거가 바뀌어 앱의 증거 대조가 어긋난다(설계 리뷰 L2).
                evidence: "데모 위험입니다(Debug 전용 검사). 이 줄을 파일에서 지우면 다음 검사에서 해결로 바뀌어요.\n파일: \(path)",
                ruleLevel: line.level, fingerprint: Fingerprint.make(checkID: id, subject: line.title, contentHash: line.level.rawValue), observedAt: Date()
            )
        }
        return CheckResult(findings: findings)
    }

    struct Line: Equatable {
        let number: Int
        let level: RiskLevel
        let title: String
    }

    /// 수준을 알 수 없거나 제목이 빈 줄은 건너뛴다. 같은 제목·수준이 겹치면 처음 것만(같은 지문).
    static func parse(_ text: String) -> [Line] {
        var lines: [Line] = []
        var seen: Set<String> = []
        // "\r\n"은 Swift에서 한 글자라 "\n"으로 나누면 두 줄이 합쳐진다 — 줄바꿈 글자 전부로 나눈다.
        for (index, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            // 수준 뒤에는 탭·전각 공백도 받는다(설계 리뷰 L1).
            let parts = trimmed.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2, let level = level(String(parts[0])) else { continue }
            let title = String(parts[1].trimmingCharacters(in: .whitespaces).prefix(HaetaeLimits.maxTitleChars))
            guard !title.isEmpty, seen.insert("\(level.rawValue)|\(title)").inserted else { continue }
            lines.append(Line(number: index + 1, level: level, title: title))
            if lines.count == maxLines { break }
        }
        return lines
    }

    private static func level(_ word: String) -> RiskLevel? {
        switch word.lowercased() {
        case "high", "높음": .high
        case "medium", "중간": .medium
        case "low", "낮음": .low
        default: nil
        }
    }
}
#endif
