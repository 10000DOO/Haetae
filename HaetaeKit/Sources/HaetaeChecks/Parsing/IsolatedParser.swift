import Foundation
import HaetaeShared

public enum IsolatedParserError: Error, Equatable {
    case inputTooLarge
    /// 해석 자식이 성공으로 끝나지 않았다(잘못된 입력, 상한, 시간 초과, 출력 잘림).
    /// 공격자가 일부러 해석 실패를 만들 수 있으니 검사는 이것을 그 파일의 Finding으로 남긴다.
    case failed
    /// 출력이 전송 형식에 맞지 않거나 상한을 넘는다 — 해석 자식이 뚫렸을 수 있다. 그 파일의 Finding으로 남긴다.
    case invalidOutput
    /// 해석 서비스를 쓸 수 없다(등록 안 됨, 서명 요구사항에 걸림, 응답 없음, 디스크의 빌드가 바뀜).
    /// 파일 탓이 아니므로 검사는 이것을 검사 실패 1건으로 올린다.
    case unavailable
}

/// 공격자가 쓸 수 있는 파일은 이것으로만 해석한다(Q42·Q48). 해석은 해석 서비스(`haetae-parser`, WO-49)가 한다 —
/// 데몬과 서명 정체가 달라 데몬의 TCC 권한을 물려받지 않는다. 데몬은 서명을 확인한 서비스에 바이트를 넘기고 결과만 검증한다.
public struct IsolatedParser: Sendable {
    /// 서비스 한 건의 최대 시간(자식 5초 + 정리 6초)보다 길어야 한다 — 짧으면 느린 파일이 `failed`가 아니라 `unavailable`이 된다.
    private static let replyTimeout: DispatchTimeInterval = .seconds(15)

    private let serviceRequirement: String
    private let options: NSXPCConnection.Options

    /// - Parameter serviceRequirement: `CodeRequirements.parser(…)`로 만든 문자열.
    public init(serviceRequirement: String) {
        self.init(serviceRequirement: serviceRequirement, options: .privileged)
    }

    /// 테스트에서 사용자 도메인의 임시 작업에 붙을 때만 `options: []`를 쓴다. 데몬 타깃에서는 보이지 않는다(`package`) —
    /// 사용자 도메인에서는 같은 사용자가 진짜 `haetae-parser` 사본을 같은 이름으로 띄울 수 있다.
    package init(serviceRequirement: String, options: NSXPCConnection.Options) {
        self.serviceRequirement = serviceRequirement
        self.options = options
    }

    /// 디코딩이 무거울 수 있어(최대 16MB) 호출한 쪽 actor를 막지 않게 따로 돈다.
    @concurrent
    public func parse(_ data: Data, as format: ParseFormat) async throws -> ParsedValue {
        guard data.count <= ParserLimits.maxInputBytes else { throw IsolatedParserError.inputTooLarge }
        // 문법이 틀린 요구사항을 걸면 NSXPC가 ObjC 예외로 프로세스(root 데몬)를 죽인다.
        guard CodeRequirements.compileStatus(serviceRequirement) == errSecSuccess else { throw IsolatedParserError.unavailable }
        let reply: Reply
        do {
            reply = try await request(data, format)
        } catch is ConnectionFailure {
            // 서비스가 유휴 종료하는 순간과 겹치면 연결이 끊긴다. 한 번만 다시 한다(launchd가 다시 띄운다).
            do { reply = try await request(data, format) } catch is ConnectionFailure { throw IsolatedParserError.unavailable }
        }
        guard !reply.unavailable else { throw IsolatedParserError.unavailable }
        guard let output = reply.output else { throw IsolatedParserError.failed }
        // 해석 자식이 뚫렸으면 출력도 공격자 것이다. 깊은 중첩·많은 객체로 디코딩 스택·메모리를 넘기지 못하게 먼저 훑는다.
        guard output.count <= ParserLimits.maxOutputBytes, Self.withinWireLimits(output),
              let value = try? JSONWire.decode(output, maxBytes: ParserLimits.maxOutputBytes) as ParsedValue,
              Self.nodeCount(value, limit: ParserLimits.maxNodes) <= ParserLimits.maxNodes
        else { throw IsolatedParserError.invalidOutput }
        return value
    }

    private struct Reply: Sendable {
        let output: Data?
        let unavailable: Bool
    }

    /// 연결이 끊기거나 서명 요구사항에 걸렸다.
    private struct ConnectionFailure: Error {}

    /// 파일마다 연결을 새로 연다. 답·연결 오류·타임아웃·취소 중 먼저 온 쪽만 결과가 된다.
    private func request(_ data: Data, _ format: ParseFormat) async throws -> Reply {
        let connection = NSXPCConnection(machServiceName: HaetaeParserXPC.machServiceName, options: options)
        connection.remoteObjectInterface = NSXPCInterface(with: (any HaetaeParserXPCProtocol).self)
        // 이 서비스만 믿는다. 메시지마다 다시 검사된다. resume 전에 걸어야 한다.
        connection.setCodeSigningRequirement(serviceRequirement)
        connection.resume()
        // 닫으면 서비스가 아직 돌고 있는 그 요청을 취소한다(타임아웃·취소 때).
        defer { connection.invalidate() }

        let slot = ContinuationSlot<Reply>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                slot.store(continuation)
                // 이미 취소된 채 들어왔으면 onCancel이 slot을 비우기 전에 돌았을 수 있다.
                if Task.isCancelled {
                    slot.take()?.resume(throwing: CancellationError())
                    return
                }
                let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                    slot.take()?.resume(throwing: ConnectionFailure())
                }
                guard let service = proxy as? any HaetaeParserXPCProtocol else {
                    slot.take()?.resume(throwing: IsolatedParserError.unavailable)
                    return
                }
                service.parse(data, format: format.rawValue) { output, unavailable in
                    slot.take()?.resume(returning: Reply(output: output, unavailable: unavailable))
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + Self.replyTimeout) {
                    slot.take()?.resume(throwing: IsolatedParserError.unavailable)
                }
            }
        } onCancel: {
            slot.take()?.resume(throwing: CancellationError())
        }
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
