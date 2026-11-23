import Foundation

/// 데몬과 해석 서비스(`haetae-parser`) 사이의 계약(Q54). 데몬만 붙을 수 있다 — 서비스가 서명 요구사항으로 거른다.
@objc public protocol HaetaeParserXPCProtocol {
    /// - Parameters:
    ///   - format: `ParseFormat`의 rawValue.
    ///   - reply: 해석 결과(전송 형식 JSON)와 "해석기를 쓸 수 없음" 여부. 결과가 nil이고 뒤가 false면 그 파일을 해석하지 못한 것이다.
    func parse(_ data: Data, format: String, withReply reply: @escaping @Sendable (Data?, Bool) -> Void)
}

public enum HaetaeParserXPC {
    public static let machServiceName = "com.10000DOO.haetae-parser"
}
