import Foundation
import HaetaeShared
import LightweightCodeRequirements
import Security

public enum IsolatedParserError: Error, Equatable {
    case inputTooLarge
    /// 해석 프로세스가 성공으로 끝나지 않았다(잘못된 입력, 상한, 시간 초과, 출력 잘림).
    /// 공격자가 일부러 해석 실패를 만들 수 있으니 검사는 이것을 그 파일의 Finding으로 남긴다.
    case failed(exitCode: Int32, terminatedBySignal: Bool, timedOut: Bool, truncated: Bool)
    /// 출력이 전송 형식에 맞지 않거나 상한을 넘는다 — 해석 프로세스가 뚫렸을 수 있다. 그 파일의 Finding으로 남긴다.
    case invalidOutput
    /// 해석기 자체를 쓸 수 없다(자기 신원을 못 얻음, 띄우기 실패, 서명 요구사항에 걸림 — 디스크의 빌드가 바뀜).
    /// 파일 탓이 아니므로 검사는 이것을 검사 실패 1건으로 올린다.
    case unavailable
}

/// 공격자가 쓸 수 있는 파일은 이것으로만 해석한다(Q42·Q47). 파일 하나에 해석 프로세스 하나.
public struct IsolatedParser: Sendable {
    private let runner: CommandRunner

    /// - Parameter runner: `selfExecutable()`로 만든 러너. 그 러너의 자기 경로를 띄운다.
    public init(runner: CommandRunner) {
        self.runner = runner
    }

    /// 디코딩이 무거울 수 있어(최대 16MB) 호출한 쪽 actor를 막지 않게 따로 돈다.
    @concurrent
    public func parse(_ data: Data, as format: ParseFormat) async throws -> ParsedValue {
        guard data.count <= ParserLimits.maxInputBytes else { throw IsolatedParserError.inputTooLarge }
        guard let executable = runner.selfExecutablePath else { throw IsolatedParserError.unavailable }
        let output: CommandOutput
        do {
            output = try await runner.run(
                executable, ["--parse", format.rawValue], stdin: data, timeout: .seconds(5), maxBytes: ParserLimits.maxOutputBytes
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw IsolatedParserError.unavailable
        }
        // 시간 초과가 아닌 SIGKILL은 서명 요구사항에 걸린 것으로 본다(커널이 exec 때 죽임). 입력만으로는 일으키기 어렵다 —
        // 뚫린 자식은 스스로 SIGKILL할 수 있지만 그때는 정상 결과를 꾸며 낼 수도 있어, 이 구분은 보안 경계가 아니다.
        if output.terminatedBySignal, output.exitCode == SIGKILL, !output.timedOut { throw IsolatedParserError.unavailable }
        // 뚫린 자식은 종료 코드를 마음대로 고를 수 있으니 0인지만 믿는다.
        guard output.succeeded, !output.truncated else {
            throw IsolatedParserError.failed(
                exitCode: output.exitCode, terminatedBySignal: output.terminatedBySignal, timedOut: output.timedOut, truncated: output.truncated
            )
        }
        // 해석 프로세스가 뚫렸으면 출력도 공격자 것이다. 깊은 중첩·많은 객체로 디코딩 스택·메모리를 넘기지 못하게 먼저 훑는다.
        guard Self.withinWireLimits(output.stdout),
              let value = try? JSONWire.decode(output.stdout, maxBytes: ParserLimits.maxOutputBytes) as ParsedValue,
              Self.nodeCount(value, limit: ParserLimits.maxNodes) <= ParserLimits.maxNodes
        else { throw IsolatedParserError.invalidOutput }
        return value
    }

    /// 데몬 자신의 실행 파일과 그 cdhash 요구사항. 데몬은 시작할 때 한 번 이것으로 `CommandRunner`를 만든다(WO-12).
    /// cdhash로 묶는다 — 팀 ID로 묶으면 같은 팀이 서명한 예전 버전을 바꿔 둘 수 있다(D20).
    public static func selfExecutable() throws -> (path: String, requirement: LaunchCodeRequirement) {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        var running: SecRequirement?
        guard let path = Bundle.main.executablePath,
              unsafe SecCodeCopySelf([], &code) == errSecSuccess, let code,
              unsafe SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              unsafe SecCodeCopySigningInformation(staticCode, [], &info) == errSecSuccess,
              let cdhash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              // 위 cdhash는 디스크의 서명이다. 데몬이 뜬 뒤 파일을 바꿔 두면 바뀐 파일의 것이 나온다(리뷰 실측).
              // 실행 중인 코드가 이 cdhash인지 확인한다 — 다르면 공격자 파일을 요구사항으로 묶게 된다.
              unsafe SecRequirementCreateWithString("cdhash H\"\(lowercaseHex(cdhash))\"" as CFString, [], &running) == errSecSuccess,
              SecCodeCheckValidity(code, [], running) == errSecSuccess
        else { throw IsolatedParserError.unavailable }
        return (path, try LaunchCodeRequirement.allOf { CodeDirectoryHash(cdhash) })
    }

    /// 전송 형식 JSON의 중첩 깊이와 객체·구분자 수가 상한 안인지. 문자열 안의 괄호·쉼표는 세지 않는다.
    /// 정상 출력은 태그 객체(`{`)로 시작하고, 값 하나마다 태그 객체 하나·사전이면 하나 더라 객체 수는 노드 수의 두 배를,
    /// 쉼표(배열 원소·사전 항목 사이)는 노드 수를 넘지 않는다.
    static func withinWireLimits(_ json: Data) -> Bool {
        guard json.first == UInt8(ascii: "{") else { return false }
        var depth = 0
        var objects = 0
        var separators = 0
        var inString = false
        var escaped = false
        for byte in json {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""):
                inString = true
            case UInt8(ascii: "{"):
                objects += 1
                depth += 1
                guard depth <= ParserLimits.maxWireDepth, objects <= 2 * ParserLimits.maxNodes else { return false }
            case UInt8(ascii: "["):
                depth += 1
                guard depth <= ParserLimits.maxWireDepth else { return false }
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
            case UInt8(ascii: ","):
                separators += 1
                guard separators <= ParserLimits.maxNodes else { return false }
            default:
                break
            }
        }
        return true
    }

    /// 값의 개수. `limit`를 넘으면 더 세지 않는다.
    static func nodeCount(_ value: ParsedValue, limit: Int) -> Int {
        var count = 0
        func visit(_ value: ParsedValue) {
            guard count <= limit else { return }
            count += 1
            switch value {
            case .array(let items): items.forEach(visit)
            case .object(let members): members.values.forEach(visit)
            default: break
            }
        }
        visit(value)
        return count
    }
}
