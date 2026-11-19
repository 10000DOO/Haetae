import Foundation

/// 메서드는 4개로 고정한다(D27). 경로·명령 같은 인자는 받지 않는다.
/// Data와 NSError만 오가므로 NSXPCInterface 클래스 허용 목록 설정이 필요 없다(D9).
@objc public protocol HaetaeXPCProtocol {
    func collect(withReply reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func ack(_ fingerprintsJSON: Data, withReply reply: @escaping @Sendable (NSError?) -> Void)
    func installPatterns(_ pack: Data, signature: Data, withReply reply: @escaping @Sendable (NSError?) -> Void)
    func markUserQuit(withReply reply: @escaping @Sendable () -> Void)
}

public enum HaetaeXPC {
    public static let machServiceName = "com.10000DOO.haetaed"
    public static let errorDomain = "com.10000DOO.haetaed"

    public static func encodeAck(_ fingerprints: [String]) throws -> Data {
        try validateAck(fingerprints)
        return try JSONWire.encode(fingerprints)
    }

    /// `ack`로 받은 데이터는 이 함수로만 푼다(D9).
    public static func decodeAck(_ data: Data) throws -> [String] {
        let fingerprints: [String] = try JSONWire.decode(data, maxBytes: HaetaeLimits.maxAckBytes)
        try validateAck(fingerprints)
        return fingerprints
    }

    private static func validateAck(_ fingerprints: [String]) throws(WireValidationError) {
        guard fingerprints.count <= HaetaeLimits.maxAckFingerprints, fingerprints.allSatisfy(Finding.isFingerprint) else {
            throw .invalidField("ack")
        }
    }
}

/// 데몬이 앱에 돌려주는 오류. 코드만 보내고 설명·경로는 싣지 않는다 — 다른 사용자의 경로가 새지 않게(T1).
public enum HaetaeXPCError: Int, CustomNSError, Sendable {
    case notImplemented = 1
    case invalidInput
    case rateLimited
    case rolledBack
    case internalError

    // 기본 브리징(`as NSError`)은 타입 이름을 도메인으로 쓴다. 어느 쪽으로 만들어도 같은 도메인이 되게 맞춘다.
    public static var errorDomain: String { HaetaeXPC.errorDomain }
    public var errorUserInfo: [String: Any] { [:] }

    public var nsError: NSError {
        NSError(domain: HaetaeXPC.errorDomain, code: rawValue)
    }
}
