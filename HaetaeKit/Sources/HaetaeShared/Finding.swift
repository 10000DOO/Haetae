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

    package static func isCheckID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= HaetaeLimits.maxCheckIDChars
            && value.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2E || $0 == 0x2D }
    }
}
