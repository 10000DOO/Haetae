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
