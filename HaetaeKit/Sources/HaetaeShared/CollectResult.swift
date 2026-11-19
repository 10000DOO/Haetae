import Foundation

public struct CollectResult: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public var findings: [Finding]
    public var resolved: [String]
    public var failedChecks: [String]
    public var patternVersion: Int
    public var daemonBuild: Int
    public var scanGap: TimeInterval?
    /// 응답 한도 때문에 이번에 보내지 못한 건수. 0이 아니면 앱이 "N건은 표시하지 못함"을 보여 준다.
    public var droppedFindings: Int?

    public init(findings: [Finding], resolved: [String], failedChecks: [String], patternVersion: Int, daemonBuild: Int, scanGap: TimeInterval? = nil, droppedFindings: Int? = nil) {
        self.schemaVersion = Self.currentSchemaVersion
        self.findings = findings
        self.resolved = resolved
        self.failedChecks = failedChecks
        self.patternVersion = patternVersion
        self.daemonBuild = daemonBuild
        self.scanGap = scanGap
        self.droppedFindings = droppedFindings
    }
}

/// 전체 디코딩 전에 읽는 머리. 모르는 키는 무시되므로 형식이 바뀐 응답에서도 읽힌다(D20: 빌드가 다르면 다시 연결).
public struct WireHeader: Decodable, Sendable, Equatable {
    public let schemaVersion: Int
    public let daemonBuild: Int
}

extension CollectResult {
    public static func decodeHeader(_ data: Data) throws -> WireHeader {
        let header: WireHeader = try JSONWire.decode(data, maxBytes: HaetaeLimits.maxReplyBytes)
        guard header.daemonBuild >= 0 else { throw WireValidationError.invalidField("version") }
        return header
    }

    /// XPC로 보낼 응답은 이 함수로만 만든다. `validate()`는 바이트 수를 보지 않으므로 인코딩한 크기도 확인한다.
    public func encodeValidated() throws -> Data {
        try validate()
        let data = try JSONWire.encode(self)
        guard data.count <= HaetaeLimits.maxReplyBytes else {
            throw WireValidationError.tooLarge(bytes: data.count, max: HaetaeLimits.maxReplyBytes)
        }
        return data
    }

    /// XPC로 받은 응답은 이 함수로만 푼다. 크기 확인 → 디코딩 → 검증을 한 번에 한다(D9).
    public static func decodeValidated(_ data: Data) throws -> CollectResult {
        let result: CollectResult = try JSONWire.decode(data, maxBytes: HaetaeLimits.maxReplyBytes)
        try result.validate()
        return result
    }

    /// 상대가 뚫렸다고 가정한 형식·길이 검증. 바이트 수는 보지 않는다(받을 때는 `decodeValidated`, 보낼 때는 `encodeValidated`가 본다).
    /// 제어문자·bidi 문자는 여기서 거부하지 않는다 — 파일 하나로 응답 전체를 막을 수 있게 되기 때문이다(치환은 데몬, 표시는 앱이 맡는다).
    public func validate() throws(WireValidationError) {
        guard schemaVersion == Self.currentSchemaVersion else { throw .unsupportedSchema(schemaVersion) }
        guard patternVersion >= 0, daemonBuild >= 0 else { throw .invalidField("version") }
        if let scanGap, !(scanGap.isFinite && scanGap >= 0) { throw .invalidField("scanGap") }
        if let droppedFindings, droppedFindings < 0 { throw .invalidField("droppedFindings") }
        guard findings.count <= HaetaeLimits.maxFindingsPerReply else { throw .invalidField("findings") }

        var perCheck: [String: Int] = [:]
        var seen = Set<String>()
        for finding in findings {
            guard Finding.isCheckID(finding.checkID) else { throw .invalidField("checkID") }
            guard finding.title.unicodeScalars.count <= HaetaeLimits.maxTitleChars else { throw .invalidField("title") }
            guard finding.evidence.unicodeScalars.count <= HaetaeLimits.maxEvidenceChars else { throw .invalidField("evidence") }
            // 지문은 식별자다(D18). 같은 값이 두 번 오면 받는 쪽 사전·목록이 깨진다.
            guard Finding.isFingerprint(finding.fingerprint), seen.insert(finding.fingerprint).inserted else { throw .invalidField("fingerprint") }
            perCheck[finding.checkID, default: 0] += 1
        }
        guard perCheck.values.allSatisfy({ $0 <= HaetaeLimits.maxFindingsPerCheck }) else { throw .invalidField("findings") }
        guard resolved.allSatisfy(Finding.isFingerprint) else { throw .invalidField("resolved") }
        guard failedChecks.allSatisfy(Finding.isCheckID) else { throw .invalidField("failedChecks") }
    }
}
