import CryptoKit
import Foundation

/// 소문자 hex. `String(format:)`은 strict memory safety에서 unsafe라 쓰지 않는다.
package func lowercaseHex(_ bytes: some Sequence<UInt8>) -> String {
    bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
}

public enum RiskLevel: String, Codable, Sendable {
    case low, medium, high

    /// 정렬·자르기 순서(높을수록 앞·남김). 데몬과 앱이 같은 순서를 쓴다.
    package var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }
}

public struct Finding: Codable, Sendable, Hashable {
    public var checkID: String
    public var title: String
    public var evidence: String
    public var ruleLevel: RiskLevel
    /// 소문자 hex SHA-256 (64자)
    public var fingerprint: String
    public var observedAt: Date

    public init(checkID: String, title: String, evidence: String, ruleLevel: RiskLevel, fingerprint: String, observedAt: Date) {
        self.checkID = checkID
        self.title = title
        self.evidence = evidence
        self.ruleLevel = ruleLevel
        self.fingerprint = fingerprint
        self.observedAt = observedAt
    }

    public static func isFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// 증거의 SHA-256(소문자 hex). 알림 완료 요약에 싣는다 — 앱이 자기 기록(사용자가 바꿀 수 있는 파일)의 증거를 확인한다(Q71).
    public static func evidenceHash(_ evidence: String) -> String {
        lowercaseHex(SHA256.hash(data: Data(evidence.utf8)))
    }

    /// 결합 문자(Mn·Me)는 글자 하나에 이만큼만 남긴다 — 수천 개를 쌓아 화면을 덮지 못하게(Zalgo). 일반 글자는 3개를 넘지 않는다.
    /// 띄어 쓰는 결합 문자(Mc — 버마어 등)는 세지 않는다.
    package static let maxCombiningMarks = 4

    /// 화면에 그리기 전 글을 정리한다(데몬이 검사 결과에, 앱이 판정 이유에 쓴다). 제어 문자는 JSON에서 6바이트로 늘어 원장을 불리고,
    /// 방향 제어 문자는 화면에서 글자 순서를 뒤집는다(`gpj.exe` → `exe.jpg`). 사설 영역(애플 로고 같은 모양으로 제목을 꾸밈)·미할당·
    /// 서로게이트, 기본적으로 보이지 않는 문자(변형 선택자, 한글 채움 문자, 태그 문자 — 보이지 않게 데이터를 실어 LLM에 넣는 데 쓰임)와
    /// 점자 빈칸도 공백으로 바꾸고, 결합 문자는 이어서 `maxCombiningMarks`개까지만 둔다. `multiline`이면 줄바꿈·탭은 둔다.
    package static func displaySafe(_ text: String, multiline: Bool) -> String {
        var scalars = String.UnicodeScalarView()
        var marks = 0
        for scalar in text.unicodeScalars {
            let properties = scalar.properties
            switch properties.generalCategory {
            case .control where multiline && (scalar == "\n" || scalar == "\t"):
                scalars.append(scalar)
                marks = 0
            case .control, .format, .lineSeparator, .paragraphSeparator, .privateUse, .unassigned, .surrogate:
                scalars.append(" ")
                marks = 0
            case _ where properties.isDefaultIgnorableCodePoint || scalar.value == 0x2800:
                scalars.append(" ")
                marks = 0
            case .nonspacingMark, .enclosingMark:
                marks += 1
                if marks <= maxCombiningMarks { scalars.append(scalar) }
            default:
                scalars.append(scalar)
                marks = 0
            }
        }
        return String(scalars)
    }

    package static func isCheckID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= HaetaeLimits.maxCheckIDChars
            && value.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2E || $0 == 0x2D }
    }
}
