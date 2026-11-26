/// 앱에 같이 넣는 기본 패턴 팩(D23). SwiftPM 리소스 번들은 쓰지 않는다 —
/// haetaed는 앱 번들 안으로 복사되는 명령줄 도구라 `Bundle.module`을 찾지 못한다.
enum DefaultPatterns {
    static let json = #"{"formatVersion":1,"version":1,"checks":{}}"#
}
