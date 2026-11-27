import Foundation
import HaetaeShared
import os

/// 패턴 팩 안의 값. 검사마다 자기 구역의 모양이 달라 타입을 고정하지 않는다.
public enum JSONValue: Sendable, Equatable, Decodable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }
}

extension JSONValue {
    /// 사전의 값. 사전이 아니거나 키가 없으면 nil.
    subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    /// 문자열 배열. 문자열이 아닌 항목이 하나라도 있으면 nil(팩을 잘못 만든 것).
    var strings: [String]? {
        guard case .array(let values) = self else { return nil }
        let strings = values.compactMap { if case .string(let string) = $0 { string } else { nil } }
        return strings.count == values.count ? strings : nil
    }

    var number: Double? {
        if case .number(let value) = self { value } else { nil }
    }
}

public struct PatternPack: Sendable, Equatable, Decodable {
    public static let supportedFormatVersion = 1

    public let formatVersion: Int
    public let version: Int
    /// 키는 `checkID`.
    public let checks: [String: JSONValue]
}

/// 검사 기준 데이터(D23). 지금은 내장 기본 팩만 읽는다 — 서명 검증과 설치는 WO-41.
public struct PatternStore: Sendable {
    private static let builtIn: PatternPack = {
        do {
            let pack: PatternPack = try JSONWire.decode(Data(DefaultPatterns.json.utf8), maxBytes: HaetaeLimits.maxPatternPackBytes)
            guard pack.formatVersion == PatternPack.supportedFormatVersion else { throw WireValidationError.invalidField("formatVersion") }
            return pack
        } catch {
            // 버전 0이 패널에 보인다 — 기본 팩이 깨진 빌드다.
            ChecksLog.patterns.fault("기본 패턴 팩을 읽지 못함")
            return PatternPack(formatVersion: PatternPack.supportedFormatVersion, version: 0, checks: [:])
        }
    }()

    public init() {}

    public var current: PatternPack { Self.builtIn }
}
