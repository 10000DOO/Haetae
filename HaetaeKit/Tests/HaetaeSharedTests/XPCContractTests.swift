import Foundation
import Testing
@testable import HaetaeShared

@Suite("HaetaeXPC ack 인코딩·디코딩")
struct AckTests {
    @Test("지문 목록이 왕복한다", arguments: [0, 1, HaetaeLimits.maxAckFingerprints])
    func roundTrip(count: Int) throws {
        let fingerprints = (0..<count).map(fingerprint)
        #expect(try HaetaeXPC.decodeAck(HaetaeXPC.encodeAck(fingerprints)) == fingerprints)
    }

    @Test("1,001개는 보내지도 받지도 않는다")
    func rejectsTooMany() throws {
        let fingerprints = (0...HaetaeLimits.maxAckFingerprints).map(fingerprint)
        #expect(throws: WireValidationError.invalidField("ack")) { try HaetaeXPC.encodeAck(fingerprints) }

        let data = try JSONWire.encode(fingerprints)
        #expect(data.count <= HaetaeLimits.maxAckBytes, "크기가 아니라 개수로 걸러야 한다")
        #expect(throws: WireValidationError.invalidField("ack")) { try HaetaeXPC.decodeAck(data) }
    }

    @Test("형식이 틀린 지문이 하나라도 있으면 거부한다", arguments: [
        hexPattern.uppercased(), String(hexPattern.dropLast()), hexPattern + "0", "g" + String(hexPattern.dropFirst()), "", " " + String(hexPattern.dropFirst()),
    ])
    func rejectsMalformed(_ bad: String) throws {
        let fingerprints = [fingerprint(1), bad]
        #expect(throws: WireValidationError.invalidField("ack")) { try HaetaeXPC.encodeAck(fingerprints) }
        let data = try JSONWire.encode(fingerprints)
        #expect(throws: WireValidationError.invalidField("ack")) { try HaetaeXPC.decodeAck(data) }
    }

    @Test("배열이 아니거나 문자열 배열이 아니면 디코딩 오류다", arguments: [#"{"ack":[]}"#, "[1,2]", "null", "not json"])
    func rejectsWrongShape(_ json: String) {
        #expect(throws: DecodingError.self) { try HaetaeXPC.decodeAck(Data(json.utf8)) }
    }

    @Test("maxAckBytes를 넘으면 디코딩 전에 거부하고, 정확히 maxAckBytes면 받는다")
    func byteLimit() throws {
        let over = padded(Data("[]".utf8), to: HaetaeLimits.maxAckBytes + 1)
        #expect(throws: WireValidationError.tooLarge(bytes: HaetaeLimits.maxAckBytes + 1, max: HaetaeLimits.maxAckBytes)) {
            try HaetaeXPC.decodeAck(over)
        }
        #expect(try HaetaeXPC.decodeAck(padded(Data("[]".utf8), to: HaetaeLimits.maxAckBytes)).isEmpty)
    }
}

@Suite("HaetaeXPCError")
struct XPCErrorTests {
    // 코드는 데몬이 앱으로 보내는 XPC 계약 값이다. 순서를 바꾸면 앱이 다른 오류로 읽는다.
    @Test("코드·도메인이 고정되고 userInfo가 비어 있다", arguments: [
        (HaetaeXPCError.notImplemented, 1), (.invalidInput, 2), (.rateLimited, 3), (.rolledBack, 4), (.internalError, 5),
    ])
    func nsErrorCarriesOnlyCode(_ error: HaetaeXPCError, code: Int) {
        #expect(error.rawValue == code)

        let made = error.nsError
        #expect(made.domain == "com.10000DOO.haetaed")
        #expect(made.code == code)
        #expect(made.userInfo.isEmpty)

        let bridged = error as NSError
        #expect(bridged.domain == "com.10000DOO.haetaed")
        #expect(bridged.code == code)
        #expect(bridged.userInfo.isEmpty)
    }
}

@Suite("HaetaeXPC 이름")
struct XPCNameTests {
    @Test("서비스 이름과 오류 도메인이 고정돼 있다")
    func namesAreFixed() {
        // launchd plist(Support/LaunchDaemons/com.10000DOO.haetaed.plist)의 MachServices 키와 같아야 앱이 데몬을 찾는다.
        #expect(HaetaeXPC.machServiceName == "com.10000DOO.haetaed")
        #expect(HaetaeXPC.errorDomain == "com.10000DOO.haetaed")
    }
}

@Suite("HaetaeLimits 관계")
struct LimitsTests {
    @Test("응답 한 번에 받은 지문을 ack 한 번에 모두 보낼 수 있다")
    func fullReplyCanBeAckedAtOnce() throws {
        #expect(HaetaeLimits.maxAckFingerprints == HaetaeLimits.maxFindingsPerReply)

        let reply = makeResult(findings: makeFindings(HaetaeLimits.maxFindingsPerReply))
        let received = try CollectResult.decodeValidated(reply.encodeValidated())
        let ack = try HaetaeXPC.encodeAck(received.findings.map(\.fingerprint))
        #expect(ack.count <= HaetaeLimits.maxAckBytes)
        #expect(try HaetaeXPC.decodeAck(ack).count == HaetaeLimits.maxFindingsPerReply)
    }
}
