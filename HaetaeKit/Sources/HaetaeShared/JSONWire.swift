import Foundation

public enum WireValidationError: Error, Equatable {
    case tooLarge(bytes: Int, max: Int)
    case unsupportedSchema(Int)
    case invalidField(String)
}

/// XPC로 오가는 JSON의 인코딩·디코딩. 날짜는 초 단위 ISO8601이다(소수 초는 버려진다).
public enum JSONWire {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        // 경로가 많은 evidence에서 `/`가 `\/`로 늘어나 응답 한도를 갉아먹지 않게 한다.
        encoder.outputFormatting = .withoutEscapingSlashes
        return try encoder.encode(value)
    }

    /// 크기 상한을 디코딩 전에 확인한다(D9). 앱·데몬 타깃은 이 함수를 직접 부르지 못한다(`package`) —
    /// 검증까지 끝내는 `CollectResult.decodeValidated`, `HaetaeXPC.decodeAck`만 쓴다.
    package static func decode<T: Decodable>(_ data: Data, maxBytes: Int) throws -> T {
        guard data.count <= maxBytes else {
            throw WireValidationError.tooLarge(bytes: data.count, max: maxBytes)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: data)
    }
}
