import Foundation

public enum RiskLevel: String, Codable, Sendable {
    case low, medium, high
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

    static func isCheckID(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= HaetaeLimits.maxCheckIDChars
            && value.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2E || $0 == 0x2D }
    }
}
