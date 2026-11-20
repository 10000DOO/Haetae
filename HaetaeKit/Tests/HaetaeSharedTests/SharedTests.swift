import Foundation
import Testing
@testable import HaetaeShared

// MARK: - 합성 데이터

/// 날짜는 초 단위 ISO8601로만 오가서 소수 초가 버려진다. 왕복 비교가 맞도록 정수 초를 쓴다.
let sampleDate = Date(timeIntervalSince1970: 1_800_000_000)
let sampleDateText = "2027-01-15T08:00:00Z"

/// 합성 지문: index를 64자리 소문자 hex로.
func fingerprint(_ index: Int) -> String {
    let hex = String(index, radix: 16)
    return String(repeating: "0", count: 64 - hex.count) + hex
}

func makeFinding(_ index: Int = 0, checkID: String = "test.sample", title: String = "Synthetic finding", evidence: String = "/Library/LaunchDaemons/com.example.agent.plist", fingerprint override: String? = nil) -> Finding {
    Finding(checkID: checkID, title: title, evidence: evidence, ruleLevel: .medium, fingerprint: override ?? fingerprint(index), observedAt: sampleDate)
}

/// 검사 하나에 `maxFindingsPerCheck`건씩 나눠 담는다 — 응답당 개수만 시험하도록 검사별 한도와 지문 중복은 피한다.
func makeFindings(_ count: Int, title: String = "Synthetic finding", evidence: String = "synthetic evidence") -> [Finding] {
    (0..<count).map { makeFinding($0, checkID: "test.check-\($0 / HaetaeLimits.maxFindingsPerCheck)", title: title, evidence: evidence) }
}

func makeResult(findings: [Finding] = [makeFinding()], resolved: [String] = [], failedChecks: [String] = [], patternVersion: Int = 1, daemonBuild: Int = 1, scanGap: TimeInterval? = nil, droppedFindings: Int? = nil) -> CollectResult {
    CollectResult(findings: findings, resolved: resolved, failedChecks: failedChecks, patternVersion: patternVersion, daemonBuild: daemonBuild, scanGap: scanGap, droppedFindings: droppedFindings)
}

/// 유효한 JSON 뒤에 공백을 붙여 정확히 `count`바이트로 만든다.
func padded(_ json: Data, to count: Int) -> Data {
    json + Data(repeating: 0x20, count: count - json.count)
}

/// 글자(grapheme)는 1개지만 Unicode scalar는 `scalars`개인 문자열.
func combining(scalars: Int) -> String {
    "e" + String(repeating: "\u{0301}", count: scalars - 1)
}

let hexPattern = String(repeating: "0123456789abcdef", count: 4)

// MARK: - JSON 형식

@Suite("JSON 형식")
struct WireFormatTests {
    @Test("Finding이 JSON 왕복 후 같다", arguments: [RiskLevel.low, .medium, .high])
    func findingRoundTrip(_ level: RiskLevel) throws {
        var finding = makeFinding(7, title: "제목 — 합성", evidence: "line1\nline2 \"quoted\"")
        finding.ruleLevel = level
        let decoded: Finding = try JSONWire.decode(JSONWire.encode(finding), maxBytes: 10_000)
        #expect(decoded == finding)
    }

    @Test("CollectResult가 encodeValidated → decodeValidated 왕복 후 같다")
    func collectResultRoundTrip() throws {
        let full = makeResult(findings: [makeFinding(1), makeFinding(2, checkID: "log.auth")], resolved: [fingerprint(99)], failedChecks: ["network.trust"], patternVersion: 3, daemonBuild: 42, scanGap: 120, droppedFindings: 5)
        let minimal = makeResult(findings: [])
        for result in [full, minimal] {
            #expect(try CollectResult.decodeValidated(result.encodeValidated()) == result)
        }
    }

    // 키 이름은 XPC 형식이자 디스크 저장 형식(risks.json, ledger)이라 바뀌면 안 된다.
    @Test("고정 JSON 문자열이 Finding으로 디코딩된다")
    func findingKeyNamesAreFixed() throws {
        let json = #"{"checkID":"persistence.launch-items","title":"Unsigned launch daemon","evidence":"/Library/LaunchDaemons/com.example.agent.plist","ruleLevel":"high","fingerprint":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","observedAt":"2027-01-15T08:00:00Z"}"#
        let finding: Finding = try JSONWire.decode(Data(json.utf8), maxBytes: 10_000)
        #expect(finding == Finding(checkID: "persistence.launch-items", title: "Unsigned launch daemon", evidence: "/Library/LaunchDaemons/com.example.agent.plist", ruleLevel: .high, fingerprint: hexPattern, observedAt: sampleDate))
    }

    @Test("고정 JSON 문자열이 CollectResult로 디코딩되고, 없는 선택 키는 nil이다")
    func collectResultKeyNamesAreFixed() throws {
        let finding = #"{"checkID":"log.auth","title":"t","evidence":"e","ruleLevel":"low","fingerprint":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef","observedAt":"2027-01-15T08:00:00Z"}"#
        let full = #"{"schemaVersion":1,"findings":[\#(finding)],"resolved":["\#(fingerprint(9))"],"failedChecks":["network.trust"],"patternVersion":3,"daemonBuild":42,"scanGap":120,"droppedFindings":2}"#
        let minimal = #"{"schemaVersion":1,"findings":[],"resolved":[],"failedChecks":[],"patternVersion":0,"daemonBuild":0}"#

        let decoded = try CollectResult.decodeValidated(Data(full.utf8))
        let expected = makeResult(findings: [Finding(checkID: "log.auth", title: "t", evidence: "e", ruleLevel: .low, fingerprint: hexPattern, observedAt: sampleDate)], resolved: [fingerprint(9)], failedChecks: ["network.trust"], patternVersion: 3, daemonBuild: 42, scanGap: 120, droppedFindings: 2)
        #expect(decoded == expected)

        let decodedMinimal = try CollectResult.decodeValidated(Data(minimal.utf8))
        #expect(decodedMinimal.scanGap == nil)
        #expect(decodedMinimal.droppedFindings == nil)
    }

    @Test("인코딩한 키 이름과 날짜 형식이 고정 목록과 같다")
    func encodedKeysAreFixed() throws {
        let result = makeResult(resolved: [fingerprint(9)], failedChecks: ["log.auth"], scanGap: 60, droppedFindings: 0)
        let object = try #require(JSONSerialization.jsonObject(with: result.encodeValidated()) as? [String: Any])
        #expect(Set(object.keys) == ["schemaVersion", "findings", "resolved", "failedChecks", "patternVersion", "daemonBuild", "scanGap", "droppedFindings"])
        let finding = try #require((object["findings"] as? [[String: Any]])?.first)
        #expect(Set(finding.keys) == ["checkID", "title", "evidence", "ruleLevel", "fingerprint", "observedAt"])
        #expect(finding["observedAt"] as? String == sampleDateText)
    }

    @Test("RiskLevel 원시값이 고정돼 있다", arguments: [(RiskLevel.low, "low"), (.medium, "medium"), (.high, "high")])
    func riskLevelRawValues(_ level: RiskLevel, raw: String) {
        #expect(level.rawValue == raw)
    }

    @Test("모르는 RiskLevel 값이 오면 디코딩이 실패한다")
    func unknownRiskLevelFails() {
        let json = #"{"checkID":"log.auth","title":"t","evidence":"e","ruleLevel":"critical","fingerprint":"\#(hexPattern)","observedAt":"\#(sampleDateText)"}"#
        #expect(throws: DecodingError.self) {
            let _: Finding = try JSONWire.decode(Data(json.utf8), maxBytes: 10_000)
        }
    }

    @Test("`/`를 `\\/`로 이스케이프하지 않는다")
    func slashesAreNotEscaped() throws {
        let text = String(decoding: try JSONWire.encode(makeFinding()), as: UTF8.self)
        #expect(text.contains("/Library/LaunchDaemons/com.example.agent.plist"))
        #expect(!text.contains(#"\/"#))
    }
}

// MARK: - JSONWire.decode

@Suite("JSONWire.decode 크기 상한")
struct JSONWireDecodeTests {
    @Test("maxBytes를 넘으면 디코딩 전에 tooLarge로 거부한다")
    func rejectsBeforeDecoding() {
        // JSON이 아닌 바이트라도 크기 오류가 먼저 나와야 디코더에 닿지 않은 것이다.
        let garbage = Data(repeating: 0xFF, count: 17)
        #expect(throws: WireValidationError.tooLarge(bytes: 17, max: 16)) {
            let _: [String] = try JSONWire.decode(garbage, maxBytes: 16)
        }
        #expect(throws: DecodingError.self) {
            let _: [String] = try JSONWire.decode(garbage.dropLast(), maxBytes: 16)
        }
    }

    @Test("정확히 maxBytes면 디코딩한다")
    func acceptsExactlyMaxBytes() throws {
        let data = padded(Data("[]".utf8), to: 16)
        let decoded: [String] = try JSONWire.decode(data, maxBytes: 16)
        #expect(decoded.isEmpty)
    }
}

// MARK: - CollectResult.validate

struct InvalidReply: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let result: CollectResult
    let error: WireValidationError
}

let invalidReplies: [InvalidReply] = [
    .init(testDescription: "음수 patternVersion", result: makeResult(patternVersion: -1), error: .invalidField("version")),
    .init(testDescription: "음수 daemonBuild", result: makeResult(daemonBuild: -1), error: .invalidField("version")),
    .init(testDescription: "scanGap NaN", result: makeResult(scanGap: .nan), error: .invalidField("scanGap")),
    .init(testDescription: "scanGap +무한", result: makeResult(scanGap: .infinity), error: .invalidField("scanGap")),
    .init(testDescription: "scanGap -무한", result: makeResult(scanGap: -.infinity), error: .invalidField("scanGap")),
    .init(testDescription: "음수 scanGap", result: makeResult(scanGap: -1), error: .invalidField("scanGap")),
    .init(testDescription: "음수 droppedFindings", result: makeResult(droppedFindings: -1), error: .invalidField("droppedFindings")),
    .init(testDescription: "findings 1,001건", result: makeResult(findings: makeFindings(HaetaeLimits.maxFindingsPerReply + 1)), error: .invalidField("findings")),
    .init(testDescription: "한 검사에 201건", result: makeResult(findings: (0...HaetaeLimits.maxFindingsPerCheck).map { makeFinding($0, checkID: "test.same") }), error: .invalidField("findings")),
    .init(testDescription: "결합 문자로 부풀린 title (글자 1개, scalar 201개)", result: makeResult(findings: [makeFinding(title: combining(scalars: HaetaeLimits.maxTitleChars + 1))]), error: .invalidField("title")),
    .init(testDescription: "결합 문자로 부풀린 evidence (글자 1개, scalar 2,001개)", result: makeResult(findings: [makeFinding(evidence: combining(scalars: HaetaeLimits.maxEvidenceChars + 1))]), error: .invalidField("evidence")),
    .init(testDescription: "지문 대문자 hex", result: makeResult(findings: [makeFinding(fingerprint: hexPattern.uppercased())]), error: .invalidField("fingerprint")),
    .init(testDescription: "지문 63자", result: makeResult(findings: [makeFinding(fingerprint: String(hexPattern.dropLast()))]), error: .invalidField("fingerprint")),
    .init(testDescription: "지문 65자", result: makeResult(findings: [makeFinding(fingerprint: hexPattern + "0")]), error: .invalidField("fingerprint")),
    .init(testDescription: "지문에 hex 아닌 글자", result: makeResult(findings: [makeFinding(fingerprint: "g" + String(hexPattern.dropFirst()))]), error: .invalidField("fingerprint")),
    .init(testDescription: "지문 중복 (검사가 달라도)", result: makeResult(findings: [makeFinding(1), makeFinding(1, checkID: "test.other")]), error: .invalidField("fingerprint")),
    .init(testDescription: "checkID 빈 문자열", result: makeResult(findings: [makeFinding(checkID: "")]), error: .invalidField("checkID")),
    .init(testDescription: "checkID 대문자", result: makeResult(findings: [makeFinding(checkID: "Log.auth")]), error: .invalidField("checkID")),
    .init(testDescription: "checkID 101자", result: makeResult(findings: [makeFinding(checkID: String(repeating: "a", count: HaetaeLimits.maxCheckIDChars + 1))]), error: .invalidField("checkID")),
    .init(testDescription: "checkID에 슬래시", result: makeResult(findings: [makeFinding(checkID: "log/../auth")]), error: .invalidField("checkID")),
    .init(testDescription: "checkID에 밑줄", result: makeResult(findings: [makeFinding(checkID: "log_auth")]), error: .invalidField("checkID")),
    .init(testDescription: "checkID에 비ASCII",result: makeResult(findings: [makeFinding(checkID: "log.검사")]), error: .invalidField("checkID")),
    .init(testDescription: "resolved 형식 오류", result: makeResult(resolved: [fingerprint(1), "not-a-fingerprint"]), error: .invalidField("resolved")),
    .init(testDescription: "failedChecks 형식 오류", result: makeResult(failedChecks: ["log.auth", "Bad Check"]), error: .invalidField("failedChecks")),
]

struct ValidReply: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let result: CollectResult
}

let validReplies: [ValidReply] = [
    .init(testDescription: "빈 응답", result: makeResult(findings: [])),
    .init(testDescription: "정확히 1,000건 (검사 5개 × 200건)", result: makeResult(findings: makeFindings(HaetaeLimits.maxFindingsPerReply))),
    .init(testDescription: "한 검사에 정확히 200건", result: makeResult(findings: (0..<HaetaeLimits.maxFindingsPerCheck).map { makeFinding($0, checkID: "test.same") })),
    .init(testDescription: "title scalar 200개 (결합 문자)", result: makeResult(findings: [makeFinding(title: combining(scalars: HaetaeLimits.maxTitleChars))])),
    .init(testDescription: "evidence scalar 2,000개 (결합 문자)", result: makeResult(findings: [makeFinding(evidence: combining(scalars: HaetaeLimits.maxEvidenceChars))])),
    .init(testDescription: "checkID 100자, 허용 글자 전부", result: makeResult(findings: [makeFinding(checkID: "abcdefghijklmnopqrstuvwxyz0123456789.-" + String(repeating: "a", count: HaetaeLimits.maxCheckIDChars - 38))])),
    .init(testDescription: "scanGap 0, droppedFindings 0", result: makeResult(scanGap: 0, droppedFindings: 0)),
    // 제어문자·bidi 문자는 validate가 거부하지 않는다(치환은 데몬, 표시는 앱 — WO-2 6번).
    .init(testDescription: "제어문자·bidi 문자가 든 title·evidence", result: makeResult(findings: [makeFinding(title: "\u{202E}txt.exe\u{0007}", evidence: "a\u{0000}b\u{001B}[2J")])),
    .init(testDescription: "정상 resolved·failedChecks", result: makeResult(resolved: [fingerprint(5000)], failedChecks: ["log.auth", "network.dns-proxy"])),
]

@Suite("CollectResult.validate")
struct ValidateTests {
    @Test("분기별로 거부한다", arguments: invalidReplies)
    func rejects(_ reply: InvalidReply) {
        #expect(throws: reply.error) { try reply.result.validate() }
    }

    @Test("경계값은 통과하고 왕복해도 같다", arguments: validReplies)
    func acceptsBoundary(_ reply: ValidReply) throws {
        try reply.result.validate()
        #expect(try CollectResult.decodeValidated(reply.result.encodeValidated()) == reply.result)
    }

    @Test("결합 문자 시험 문자열은 String.count로는 1글자다")
    func combiningStringIsOneCharacter() {
        let text = combining(scalars: HaetaeLimits.maxTitleChars + 1)
        #expect(text.count == 1)
        #expect(text.unicodeScalars.count == HaetaeLimits.maxTitleChars + 1)
    }
}

// MARK: - decodeHeader

@Suite("CollectResult.decodeHeader")
struct DecodeHeaderTests {
    @Test("정상 응답에서 스키마 버전과 데몬 빌드를 읽는다")
    func readsHeader() throws {
        let header = try CollectResult.decodeHeader(makeResult(daemonBuild: 42).encodeValidated())
        #expect(header.schemaVersion == CollectResult.currentSchemaVersion)
        #expect(header.daemonBuild == 42)
    }

    @Test("모르는 키·다른 스키마에서도 머리는 읽힌다")
    func readsHeaderOfOtherSchema() throws {
        let data = Data(#"{"schemaVersion":2,"daemonBuild":42,"findings":"different shape","newKey":{"nested":[1,2]}}"#.utf8)
        let header = try CollectResult.decodeHeader(data)
        #expect(header.schemaVersion == 2)
        #expect(header.daemonBuild == 42)
        // 같은 데이터를 전체 디코딩하면 실패한다 — 머리를 먼저 읽는 이유.
        #expect(throws: DecodingError.self) { try CollectResult.decodeValidated(data) }
    }

    @Test("음수 daemonBuild는 거부한다")
    func rejectsNegativeBuild() {
        let data = Data(#"{"schemaVersion":1,"daemonBuild":-1}"#.utf8)
        #expect(throws: WireValidationError.invalidField("version")) { try CollectResult.decodeHeader(data) }
    }

    @Test("maxReplyBytes를 넘으면 거부한다")
    func rejectsOversized() throws {
        let data = padded(try makeResult().encodeValidated(), to: HaetaeLimits.maxReplyBytes + 1)
        #expect(throws: WireValidationError.tooLarge(bytes: HaetaeLimits.maxReplyBytes + 1, max: HaetaeLimits.maxReplyBytes)) {
            try CollectResult.decodeHeader(data)
        }
    }
}

// MARK: - decodeValidated · encodeValidated

@Suite("CollectResult.decodeValidated · encodeValidated")
struct ValidatedCodingTests {
    @Test("지원하지 않는 schemaVersion은 거부한다", arguments: [0, 2, -1])
    func rejectsUnsupportedSchema(_ version: Int) {
        let data = Data(#"{"schemaVersion":\#(version),"findings":[],"resolved":[],"failedChecks":[],"patternVersion":1,"daemonBuild":1}"#.utf8)
        #expect(throws: WireValidationError.unsupportedSchema(version)) { try CollectResult.decodeValidated(data) }
    }

    @Test("디코딩 뒤 validate까지 한다")
    func decodeRunsValidate() {
        let data = Data(#"{"schemaVersion":1,"findings":[],"resolved":["XYZ"],"failedChecks":[],"patternVersion":1,"daemonBuild":1}"#.utf8)
        #expect(throws: WireValidationError.invalidField("resolved")) { try CollectResult.decodeValidated(data) }
    }

    @Test("JSON의 scanGap이 Double 범위를 넘으면 받지 않는다")
    func rejectsOverflowingScanGap() {
        let data = Data(#"{"schemaVersion":1,"findings":[],"resolved":[],"failedChecks":[],"patternVersion":1,"daemonBuild":1,"scanGap":1e400}"#.utf8)
        #expect(throws: DecodingError.self) { try CollectResult.decodeValidated(data) }
    }

    @Test("모르는 키가 더 있어도 같은 스키마면 받는다")
    func ignoresUnknownKeys() throws {
        let data = Data(#"{"schemaVersion":1,"findings":[],"resolved":[],"failedChecks":[],"patternVersion":1,"daemonBuild":1,"futureField":"x"}"#.utf8)
        #expect(try CollectResult.decodeValidated(data) == makeResult(findings: []))
    }

    @Test("maxReplyBytes를 넘으면 디코딩 전에 거부한다")
    func decodeRejectsOversized() throws {
        let data = padded(try makeResult().encodeValidated(), to: HaetaeLimits.maxReplyBytes + 1)
        #expect(throws: WireValidationError.tooLarge(bytes: HaetaeLimits.maxReplyBytes + 1, max: HaetaeLimits.maxReplyBytes)) {
            try CollectResult.decodeValidated(data)
        }
    }

    @Test("encodeValidated는 validate에 걸리는 응답을 만들지 않는다")
    func encodeRunsValidate() {
        #expect(throws: WireValidationError.invalidField("version")) { try makeResult(daemonBuild: -1).encodeValidated() }
    }

    @Test("인코딩한 크기가 maxReplyBytes를 넘으면 보내지 않는다")
    func encodeRejectsOversized() throws {
        // 4바이트 UTF-8 scalar로 채우면 scalar 한도 안에서도 약 8MB가 된다.
        let wide = String(repeating: "\u{1D11E}", count: HaetaeLimits.maxEvidenceChars)
        let result = makeResult(findings: makeFindings(HaetaeLimits.maxFindingsPerReply, evidence: wide))
        try result.validate()
        let error = #expect(throws: WireValidationError.self) { try result.encodeValidated() }
        guard case .tooLarge(let bytes, let max)? = error else {
            Issue.record("tooLarge가 아님: \(String(describing: error))")
            return
        }
        #expect(max == HaetaeLimits.maxReplyBytes)
        #expect(bytes > max)
    }

    // 1970~9999년 범위는 ISO8601의 한계가 아니라 구현이 정한 정책이다(-1·0년·10000년·1e12도 정확히 왕복한다).
    // 실제로 깨지는 것은 NaN·아주 먼 과거(-1e12초 — 다시 읽히지 않아 응답 전체 거부)와 +무한(다른 날짜로 풀림)이다.
    @Test("범위 밖 observedAt은 보낼 때 거부한다", arguments: [
        TimeInterval.nan, .infinity, -.infinity, -1, -1e12, 253_402_300_800, 1e12,
    ])
    func rejectsOutOfRangeObservedAt(_ seconds: TimeInterval) {
        var finding = makeFinding()
        finding.observedAt = Date(timeIntervalSince1970: seconds)
        let result = makeResult(findings: [finding])
        #expect(throws: WireValidationError.invalidField("observedAt")) { try result.validate() }
        #expect(throws: WireValidationError.invalidField("observedAt")) { try result.encodeValidated() }
    }

    @Test("observedAt 경계값(1970-01-01 00:00:00, 9999-12-31 23:59:59 UTC)은 통과하고 왕복해도 같다", arguments: [
        TimeInterval(0), 253_402_300_799,
    ])
    func acceptsObservedAtBoundary(_ seconds: TimeInterval) throws {
        var finding = makeFinding()
        finding.observedAt = Date(timeIntervalSince1970: seconds)
        let result = makeResult(findings: [finding])
        #expect(try CollectResult.decodeValidated(result.encodeValidated()) == result)
    }

    @Test("받은 JSON의 observedAt이 1970년 이전이거나 9999년 이후면 거부한다", arguments: ["1969-12-31T23:59:59Z", "10000-01-01T00:00:00Z"])
    func decodeRejectsOutOfRangeObservedAt(_ observedAt: String) {
        let finding = #"{"checkID":"log.auth","title":"t","evidence":"e","ruleLevel":"low","fingerprint":"\#(hexPattern)","observedAt":"\#(observedAt)"}"#
        let data = Data(#"{"schemaVersion":1,"findings":[\#(finding)],"resolved":[],"failedChecks":[],"patternVersion":1,"daemonBuild":1}"#.utf8)
        #expect(throws: WireValidationError.invalidField("observedAt")) { try CollectResult.decodeValidated(data) }
    }

    @Test("ASCII로 채운 최대 응답(1,000건)은 한도 안이라 보내지고 그대로 풀린다")
    func encodeAcceptsLargestAsciiReply() throws {
        let title = String(repeating: "t", count: HaetaeLimits.maxTitleChars)
        let evidence = String(repeating: "a", count: HaetaeLimits.maxEvidenceChars)
        let result = makeResult(findings: makeFindings(HaetaeLimits.maxFindingsPerReply, title: title, evidence: evidence))
        let data = try result.encodeValidated()
        #expect(data.count <= HaetaeLimits.maxReplyBytes)
        #expect(try CollectResult.decodeValidated(data) == result)
    }
}
