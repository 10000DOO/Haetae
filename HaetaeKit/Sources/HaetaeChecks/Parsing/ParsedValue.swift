import Foundation

/// 해석 전용 프로세스(WO-47)가 돌려주는 값. plist·JSON의 값을 타입을 잃지 않고 담는다.
public enum ParsedValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case data(Data)
    case date(Date)
    case array([ParsedValue])
    case object([String: ParsedValue])
}

/// JSON은 처음 쓰는 WO-32가 중복 키 거부와 함께 더한다 — Foundation 해석기는 중복 키를 조용히 하나로 합친다(실측).
public enum ParseFormat: String, Sendable {
    case plist
}

public enum ParserLimits {
    public static let maxInputBytes = 8_000_000
    public static let maxDepth = 32
    public static let maxNodes = 100_000
    /// 입력 상한에 base64(4/3)와 태그를 더해도 정상 파일이 걸리지 않게.
    public static let maxOutputBytes = 16_000_000
    /// 전송 형식의 JSON 중첩 깊이 상한. 깊이 d의 값은 태그 객체(2d−1)와 그 안의 배열·사전(2d)으로 두 단계가 된다.
    public static let maxWireDepth = 2 * maxDepth
}

/// 전송 형식: 값마다 키 하나짜리 객체로 감싸고, 그 키가 타입을 말한다. 사전 안의 키와 섞이지 않는다.
/// 날짜는 2001년 기준 초(Foundation이 담는 값 그대로 — 1970년 기준으로 바꾸면 왕복할 때 값이 달라진다).
extension ParsedValue: Codable {
    private enum Tag: String, CodingKey {
        case n, b, i, f, s, x, t, a, o
    }

    /// 모르는 키까지 세기 위한 키. `Tag`로만 읽으면 모르는 키는 보이지 않는다.
    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Tag.self)
        switch self {
        case .null:
            try container.encodeNil(forKey: .n)
        case .bool(let value):
            try container.encode(value, forKey: .b)
        case .int(let value):
            try container.encode(value, forKey: .i)
        case .double(let value):
            try Self.encode(value, forKey: .f, in: &container)
        case .string(let value):
            try container.encode(value, forKey: .s)
        case .data(let value):
            try container.encode(value, forKey: .x)
        case .date(let value):
            // 바이너리 plist의 날짜도 실수라 NaN이 들어올 수 있다.
            try Self.encode(value.timeIntervalSinceReferenceDate, forKey: .t, in: &container)
        case .array(let value):
            try container.encode(value, forKey: .a)
        case .object(let value):
            try container.encode(value, forKey: .o)
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Tag.self)
        guard try decoder.container(keyedBy: AnyKey.self).allKeys.count == 1, let tag = container.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: container.codingPath, debugDescription: "태그는 하나여야 한다"))
        }
        switch tag {
        case .n:
            guard try container.decodeNil(forKey: .n) else {
                throw DecodingError.dataCorruptedError(forKey: .n, in: container, debugDescription: "null이 아님")
            }
            self = .null
        case .b:
            self = .bool(try container.decode(Bool.self, forKey: .b))
        case .i:
            self = .int(try container.decode(Int64.self, forKey: .i))
        case .f:
            self = .double(try Self.decodeDouble(forKey: .f, in: container))
        case .s:
            self = .string(try container.decode(String.self, forKey: .s))
        case .x:
            self = .data(try container.decode(Data.self, forKey: .x))
        case .t:
            self = .date(Date(timeIntervalSinceReferenceDate: try Self.decodeDouble(forKey: .t, in: container)))
        case .a:
            self = .array(try container.decode([ParsedValue].self, forKey: .a))
        case .o:
            self = .object(try container.decode([String: ParsedValue].self, forKey: .o))
        }
    }

    /// JSON에는 무한대·NaN이 없어 문자열로 적는다.
    private static func encode(_ value: Double, forKey key: Tag, in container: inout KeyedEncodingContainer<Tag>) throws {
        if value.isFinite {
            try container.encode(value, forKey: key)
        } else {
            try container.encode(value.isNaN ? "nan" : value > 0 ? "inf" : "-inf", forKey: key)
        }
    }

    private static func decodeDouble(forKey key: Tag, in container: KeyedDecodingContainer<Tag>) throws -> Double {
        if let value = try? container.decode(Double.self, forKey: key) { return value }
        switch try container.decode(String.self, forKey: key) {
        case "nan": return .nan
        case "inf": return .infinity
        case "-inf": return -.infinity
        default: throw DecodingError.dataCorruptedError(forKey: key, in: container, debugDescription: "알 수 없는 실수")
        }
    }
}
