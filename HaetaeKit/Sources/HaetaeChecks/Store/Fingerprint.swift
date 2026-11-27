import CryptoKit
import Foundation
import HaetaeShared

/// Finding의 식별자(D18). 같은 위험이면 실행할 때마다 같은 값이고, 내용이 바뀌면 다른 값이다.
public enum Fingerprint {
    /// SHA-256(각 부분을 `<UTF-8 길이>:<값>`으로 이어 붙인 것), 소문자 hex 64자.
    /// 구분 문자 대신 길이를 앞에 붙여 경계를 정한다 — 서명에서 읽은 TeamID처럼 바깥에서 온 값에 어떤 글자가 있어도
    /// 다른 조합과 겹치지 않고, 데몬이 멈출 일도 없다.
    public static func make(checkID: String, subject: String, contentHash: String) -> String {
        let input = [checkID, normalize(subject), contentHash].map { "\($0.utf8.count):\($0)" }.joined()
        return lowercaseHex(SHA256.hash(data: Data(input.utf8)))
    }

    /// 경로는 파일 시스템을 보지 않고 글자로만 표준화한다(`.`·`..`·겹친 `/`·끝 `/`) — 결과가 늘 같아야 해서다.
    /// APFS는 유니코드 정규화를 구분하지 않으므로 NFC로 맞춘다. 경로가 아니면 앞뒤 공백도 없앤다.
    static func normalize(_ subject: String) -> String {
        let nfc = subject.precomposedStringWithCanonicalMapping
        guard nfc.hasPrefix("/") else { return nfc.trimmingCharacters(in: .whitespacesAndNewlines) }
        var parts: [Substring] = []
        for part in nfc.split(separator: "/") where part != "." {
            if part == ".." {
                _ = parts.popLast()
            } else {
                parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }
}
