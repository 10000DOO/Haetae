import Foundation

/// 비밀번호·토큰·키처럼 보이는 값을 가린다(D30). evidence와 title은 LLM과 화면으로 가기 전에 반드시 이것을 거친다.
/// 놓치는 것보다 더 가리는 쪽을 고른다 — 가려진 evidence는 불편할 뿐이지만 새어 나간 비밀은 되돌릴 수 없다.
public enum SecretMasker {
    static let placeholder = "«가림»"

    public static func mask(_ text: String) -> String {
        var text = text
        // 순서가 있다: 뒤 규칙이 앞 규칙이 남긴 조각(`?«가림»`)을 다시 건드리지 않게 넓은 것부터 가린다.
        // 정규식은 시작 위치마다 뒤를 훑으므로 반복 길이를 묶거나, 되짚을 일이 없게 쓴다 — 아니면 공격자가 고른 긴 입력에서
        // 입력 길이의 제곱 이상으로 느려진다(8,000자 실측: URL 2초, `echo` 뒤 공백 331초).
        // 개인키는 머리와 본문 줄(줄 전체가 공백 없는 base64이거나 알려진 머리 줄·빈 줄일 때)만 가린다 — END가 없을 때 글 끝까지
        // 가리거나 본문에 공백·`:`를 받으면, 키 머리 한 줄을 앞에 넣어 뒤의 악성 명령 줄을 지울 수 있다(보안·설계 재리뷰 실측).
        text.replace(#/-----BEGIN [A-Z ]{0,40}PRIVATE KEY(?: BLOCK)?-----(?:\n(?:[A-Za-z0-9+\/=]{1,80}|(?:Proc-Type|DEK-Info|Version|Comment|Hash|Charset): [^\n]{0,80}|)(?=\n|$)){0,400}(?:\n-----END [A-Z ]{0,40}PRIVATE KEY(?: BLOCK)?-----)?/#) { _ in
            placeholder
        }
        // URL은 `user:비밀번호@`와 쿼리 문자열을 가린다(토큰이 어느 키에 실리는지 알 수 없다).
        text.replace(#/\S+/#) { maskURL($0.output) }
        text = maskSudoInput(text)
        // 인증 헤더는 방식 뒤의 값을(짧은 `Basic`도) 가린다. 알려진 방식이면 어디서든, 그 밖에는 헤더 모양(줄 첫머리, `curl -v`의
        // `> `, 따옴표 바로 뒤, `-H`·`--header` 뒤)일 때만 — 문장 중간의 `Authorization: Succeeded authorizing`(authd 로그)은 증거다.
        text.replace(#/((?:proxy-)?authorization[ \t]{0,8}:[ \t]{0,8}(?:basic|digest|negotiate|ntlm)[ \t]+)[^\s'"]+/#.ignoresCase()) {
            "\($0.output.1)\(placeholder)"
        }
        text.replace(#/((?:^[ \t]*(?:[<>][ \t]*)?|['"][ \t]*|(?:^|\s)(?:-H|--header)[ \t]+)(?:proxy-)?authorization[ \t]{0,8}:[ \t]{0,8}[A-Za-z]{1,32}[ \t]+)[^\s'"]+/#.ignoresCase().anchorsMatchLineEndings()) {
            "\($0.output.1)\(placeholder)"
        }
        // 쿠키는 `이름=값` 쌍만 가린다(따옴표 값 포함) — 뒤의 쌍 아닌 글(`; curl … | sh`)은 그대로 둬 증거가 남게. `curl -b`·`--cookie`의 값도.
        text.replace(#/((?:set-)?cookie[ \t]{0,8}:[ \t]{0,8})[^\s=;'"]{1,128}=(?:"[^"\n]{0,4096}"|[^\s;'"]{0,4096})(?:;[ \t]?[^\s=;'"]{1,128}=(?:"[^"\n]{0,4096}"|[^\s;'"]{0,4096})){0,63}/#.ignoresCase()) {
            "\($0.output.1)\(placeholder)"
        }
        text.replace(#/(\bcurl\b[^\n;|&]{0,256}?\s(?:-b|--cookie)\s+)('[^'\n]*'|"[^"\n]*"|[^\s'"]+)/#) { "\($0.output.1)\(placeholder)" }
        text.replace(#/(Bearer\s+)\S+/#.ignoresCase()) { "\($0.output.1)\(placeholder)" }
        // 명령 인자로 넘긴 비밀번호: `mysql -p비밀`, `curl -u 이름:비밀`, `sshpass -p 비밀`, `security add-…-password -w 비밀`,
        // `htpasswd -b 파일 이름 비밀`. 그 명령 안에서만 본다(`;`·`|`·`&`·줄바꿈을 넘지 않음, sshpass는 자기 옵션만).
        text.replace(#/((?:mysql|mysqldump|mysqladmin|mariadb)\b[^\n;|&]{0,256}?\s-p)(\S+)/#) { "\($0.output.1)\(placeholder)" }
        text.replace(#/(\bcurl\b[^\n;|&]{0,256}?\s(?:-u|--user)\s+[^\s:]{1,256}:)(\S+)/#) { "\($0.output.1)\(placeholder)" }
        text.replace(#/(\bsshpass\s+(?:-[A-Za-z]\S{0,64}\s+){0,4}?-p\s*)(\S+)/#) { "\($0.output.1)\(placeholder)" }
        text.replace(#/(\bsecurity\s+add-\S{0,40}password\b[^\n]{0,256}?\s-w\s+)(\S+)/#) { "\($0.output.1)\(placeholder)" }
        text.replace(#/(\bhtpasswd\s+-[A-Za-z]{0,8}b[A-Za-z]{0,8}\s+\S+\s+\S+\s+)(\S+)/#) { "\($0.output.1)\(placeholder)" }
        // `password=x`, `"token": "x"`, `--api-key x`. 이름 바로 뒤에 구분자가 와야 한다(`passwords`는 아니다).
        text.replace(#/((?:password|passwd|pwd|token|secret|api[_\-]?key)["']?(?:\s*[=:]\s*|\s+))("[^"]*"|'[^']*'|\S+)/#.ignoresCase()) {
            "\($0.output.1)\(placeholder)"
        }
        // `PASS=x`·`DB_PASS=x`·`pass:x`(openssl). `pass`는 흔한 낱말 조각(`bypass`)이라 앞이 글자가 아니고 `=`·`:`가 붙을 때만.
        text.replace(#/((?:^|[^A-Za-z])pass["']?\s{0,8}[=:]\s{0,8})("[^"\n]*"|'[^'\n]*'|\S+)/#.ignoresCase()) { "\($0.output.1)\(placeholder)" }
        text.replace(#/[0-9A-Fa-f]{32,}/#) { _ in placeholder }
        text.replace(#/[A-Za-z0-9+\/_\-]{32,}={0,2}/#) { looksEncoded($0.output) ? placeholder : String($0.output) }
        return text
    }

    /// `scheme://이름:비밀번호@호스트/…?query#fragment`에서 비밀번호와 query를 가린다. `://`가 없으면 그대로 둔다.
    private static func maskURL(_ token: Substring) -> String {
        guard let scheme = token.range(of: "://") else { return String(token) }
        var result = String(token[..<scheme.upperBound])
        let rest = token[scheme.upperBound...]
        let authorityEnd = rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex
        let authority = rest[..<authorityEnd]
        if let at = authority.lastIndex(of: "@"), let colon = authority[..<at].firstIndex(of: ":") {
            result += authority[...colon]
            result += placeholder
            result += authority[at...]
        } else {
            result += authority
        }
        let path = rest[authorityEnd...]
        guard let query = path.firstIndex(of: "?") else { return result + path }
        let fragment = path[query...].firstIndex(of: "#") ?? path.endIndex
        result += path[...query]
        result += placeholder
        result += path[fragment...]
        return result
    }

    /// `echo 비밀 | sudo -S …`와 `sudo -S … <<< 비밀`의 비밀을 가린다. `sudo -S`를 먼저 찾고 앞뒤는 직접 자른다 — 정규식 하나로
    /// 쓰면 `echo`·`sudo`마다 줄 끝까지 되짚어 긴 입력에서 수백 초가 걸린다. 정규식은 여기서 한 번만 만든다 — 반복문(또는 줄마다
    /// 부르는 함수) 안에 쓰면 돌 때마다 다시 컴파일한다(줄 8,000개에 0.8초). `Regex`는 Sendable이 아니라 static에 둘 수 없다.
    /// sudo는 앞의 환경 변수(`A=b sudo`), 경로(`/usr/bin/sudo`), 값을 받는 옵션(`-u root`), `--stdin`까지 본다.
    private static func maskSudoInput(_ text: String) -> String {
        let pipeToSudo = #/\|\s*(?:[A-Za-z_][A-Za-z0-9_]{0,63}=\S{0,64}\s+){0,4}(?:(?:\/[^\s\/]{1,32}){1,8}\/)?sudo\s+(?:-\S{1,64}\s+(?:[^\s\-]\S{0,64}\s+)?){0,8}(?:-\S{0,64}S\b|--stdin\b)/#
        let sudoWithStdin = #/sudo\s+(?:-\S{1,64}\s+(?:[^\s\-]\S{0,64}\s+)?){0,8}(?:-\S{0,64}S\b|--stdin\b)/#
        let echo = #/(?:echo|printf)\s+/#

        // echo 비밀 | sudo -S: 파이프가 있는 줄에서 처음 나온 `echo`·`printf` 뒤부터 파이프 앞 공백 전까지.
        // 파이프 뒤의 줄바꿈은 셸이 이어 붙이므로 `\s`가 넘어가게 둔다.
        var piped = ""
        var rest = text[...]
        while let pipe = rest.firstMatch(of: pipeToSudo) {
            let before = rest[..<pipe.range.lowerBound]
            let head = before[(before.lastIndex(where: \.isNewline).map(before.index(after:)) ?? before.startIndex)...]
            let end = head.lastIndex { !$0.isWhitespace }.map(head.index(after:)) ?? head.startIndex
            if let echo = head.firstMatch(of: echo), echo.range.upperBound < end {
                piped += rest[..<echo.range.upperBound]
                piped += placeholder
                piped += rest[end..<pipe.range.upperBound]
            } else {
                piped += rest[..<pipe.range.upperBound]
            }
            rest = rest[pipe.range.upperBound...]
        }
        piped += rest

        // sudo -S … <<< 비밀: sudo와 같은 줄에 있는 `<<<` 다음 덩어리(값은 `<<<` 뒤 줄이 바뀌어도 된다). 따옴표로 묶였으면
        // 닫는 따옴표까지, 같은 줄에서 닫히지 않으면 줄 끝까지만 — 글 끝까지 가리면 뒤의 증거가 지워진다.
        var masked = ""
        var tail = piped[...]
        while let sudo = tail.firstMatch(of: sudoWithStdin) {
            let rest = tail[sudo.range.upperBound...]
            guard let here = rest.range(of: "<<<") else { break }
            if let newline = rest[..<here.lowerBound].lastIndex(where: \.isNewline) {
                // `<<<`가 뒤 줄에 있다. 그 사이의 sudo는 같은 줄에 `<<<`가 없으니 `<<<`가 있는 줄로 건너뛴다 — 줄마다 다시 훑으면
                // sudo를 되풀이한 입력에서 느려진다.
                masked += tail[...newline]
                tail = tail[tail.index(after: newline)...]
                continue
            }
            let after = tail[here.upperBound...]
            let start = after.firstIndex { !$0.isWhitespace } ?? after.endIndex
            var end = after[start...].firstIndex(where: \.isWhitespace) ?? after.endIndex
            if start < after.endIndex, after[start] == "'" || after[start] == "\"" {
                let lineEnd = after[start...].firstIndex(where: \.isNewline) ?? after.endIndex
                let quoted = after[after.index(after: start)..<lineEnd]
                end = quoted.firstIndex(of: after[start]).map(quoted.index(after:)) ?? lineEnd
            }
            masked += tail[..<start]
            if start < end { masked += placeholder }
            tail = tail[end...]
        }
        masked += tail
        return masked
    }

    /// 경로와 UUID를 가리지 않으려는 구분이다: 무작위 base64는 대문자·소문자·숫자가 섞여 있고 `/`로 시작하지 않는다.
    /// shortcut: `/`로 시작하는 base64 값과 한 종류 글자만 쓴 값은 놓친다, 실제 유출 사례가 나오면 엔트로피 계산으로 바꾼다.
    private static func looksEncoded(_ chunk: Substring) -> Bool {
        !chunk.hasPrefix("/")
            && chunk.contains(where: \.isNumber)
            && chunk.contains(where: \.isUppercase)
            && chunk.contains(where: \.isLowercase)
    }
}
