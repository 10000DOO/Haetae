// xpc-probe — 데몬이 서명이 맞지 않는 클라이언트를 거부하는지 보는 시험 도구(WO-7, 3-7).
// run-probes.sh가 HaetaeShared 소스와 같이 컴파일한다(프로토콜을 복사하지 않는다).
//
// 사용법
//   xpc-probe [--no-privileged] [--timeout 초]   collect를 한 번 부르고 결과를 한 줄로 출력
//   xpc-probe --exec-swap <실행 파일>            collect를 보낸 직후 execv로 <실행 파일 --after-exec>가 된다
//   xpc-probe --hold <초>                        메시지 없이 서비스 연결만 쥐고 기다린다
// 종료 코드: 0 = 응답 없이 중단·무효화로 거부됨(기대), 1 = CollectResult로 읽히는 응답을 받음(방어 실패 — 양성 대조에서는 기대),
//           2 = 판단 불가(시간 초과, 중단·무효화가 아닌 오류), 3 = 응답은 왔지만 CollectResult가 아님(데몬 오류·읽기 실패)

import Bootstrap
import Darwin
import Foundation
import Synchronization
import XPC

enum Outcome: Sendable {
    case reply(bytes: Int)
    case unreadableReply(bytes: Int, reason: String)
    case daemonError(domain: String, code: Int)
    case rejected(domain: String, code: Int)
    case timedOut

    var line: String {
        switch self {
        case .reply(let bytes):
            "결과=성공 응답=\(bytes)바이트"
        case .unreadableReply(let bytes, let reason):
            "결과=성공 읽기실패=\(bytes)바이트 \(reason)"
        case .daemonError(let domain, let code):
            "결과=성공 데몬오류=\(domain)/\(code)"
        case .rejected(let domain, let code):
            "결과=거부 오류=\(domain)/\(code)(\(Self.name(code)))"
        case .timedOut:
            "결과=시간초과"
        }
    }

    var exitCode: Int32 {
        switch self {
        case .rejected(let domain, let code):
            domain == NSCocoaErrorDomain && (code == NSXPCConnectionInterrupted || code == NSXPCConnectionInvalid) ? 0 : 2
        case .reply: 1
        case .unreadableReply, .daemonError: 3
        case .timedOut: 2
        }
    }

    private static func name(_ code: Int) -> String {
        switch code {
        case NSXPCConnectionInterrupted: "중단"
        case NSXPCConnectionInvalid: "무효화"
        case NSXPCConnectionCodeSigningRequirementFailure: "서명 요구사항 실패"
        default: "기타"
        }
    }
}

/// 오류 핸들러와 응답 중 먼저 온 것 하나만 남긴다.
final class FirstOutcome: Sendable {
    private let value = Mutex<Outcome?>(nil)
    private let arrived = DispatchSemaphore(value: 0)

    func finish(_ outcome: Outcome) {
        let isFirst = value.withLock { stored in
            guard stored == nil else { return false }
            stored = outcome
            return true
        }
        if isFirst { arrived.signal() }
    }

    func wait(seconds: Int) -> Outcome {
        _ = arrived.wait(timeout: .now() + .seconds(seconds))
        return value.withLock { $0 } ?? .timedOut
    }
}

func makeConnection(privileged: Bool) -> NSXPCConnection {
    let connection = NSXPCConnection(machServiceName: HaetaeXPC.machServiceName, options: privileged ? .privileged : [])
    connection.remoteObjectInterface = NSXPCInterface(with: (any HaetaeXPCProtocol).self)
    return connection
}

/// collect를 보낸다. 응답이나 오류는 `outcome`에 들어간다.
func sendCollect(on connection: NSXPCConnection, outcome: FirstOutcome) {
    let proxy = connection.remoteObjectProxyWithErrorHandler { error in
        let error = error as NSError
        outcome.finish(.rejected(domain: error.domain, code: error.code))
    }
    guard let proxy = proxy as? any HaetaeXPCProtocol else {
        print("결과=판단불가 프록시를 만들지 못함")
        exit(2)
    }
    proxy.collect { data, error in
        guard let data else {
            outcome.finish(.daemonError(domain: error?.domain ?? "-", code: error?.code ?? 0))
            return
        }
        // 양성 대조는 앱과 같은 검증(D9)을 통과한 데이터만 성공으로 친다.
        do {
            _ = try CollectResult.decodeValidated(data)
            outcome.finish(.reply(bytes: data.count))
        } catch {
            outcome.finish(.unreadableReply(bytes: data.count, reason: "\(error)"))
        }
    }
}

func callCollect(privileged: Bool, timeoutSeconds: Int) -> Outcome {
    let connection = makeConnection(privileged: privileged)
    connection.resume()
    let outcome = FirstOutcome()
    sendCollect(on: connection, outcome: outcome)
    let result = outcome.wait(seconds: timeoutSeconds)
    connection.invalidate()
    return result
}

func localTime() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter.string(from: .now)
}

/// exec 전후로 mach 포트 권한이 남는지 보는 표지. 같은 이름이 새로 할당될 수 있어 context 값까지 맞춰 본다.
let markerContext: mach_port_context_t = 0x4841_4554

func execSwap(to target: String) -> Never {
    let connection = makeConnection(privileged: true)
    connection.resume()
    sendCollect(on: connection, outcome: FirstOutcome())
    // 메시지가 실제로 커널에 넘어간 뒤에 exec해야 "보낸 쪽이 바뀐" 상황이 된다.
    let sent = DispatchSemaphore(value: 0)
    connection.scheduleSendBarrierBlock { sent.signal() }
    guard sent.wait(timeout: .now() + .seconds(5)) == .success else {
        print("결과=판단불가 collect를 보내지 못함")
        exit(2)
    }

    let task = mach_task_self_
    var marker = mach_port_name_t(MACH_PORT_NULL)
    guard mach_port_allocate(task, MACH_PORT_RIGHT_RECEIVE, &marker) == KERN_SUCCESS,
          mach_port_set_context(task, marker, markerContext) == KERN_SUCCESS else {
        print("결과=판단불가 표지 포트를 만들지 못함")
        exit(2)
    }

    var arguments = [target, "--after-exec", String(marker)].map { strdup($0) } + [nil]
    execv(target, &arguments)
    print("결과=판단불가 execv 실패 errno=\(errno)")
    exit(2)
}

/// exec 뒤의 새 이미지. 옛 NSXPCConnection은 메모리째 사라졌으므로 같은 연결로 다시 부를 방법이 없다.
/// 포트 권한이 남았는지만 확인하고, 새 연결로 한 번 더 부른다.
func afterExec(marker: mach_port_name_t) -> Never {
    let startedAt = localTime()
    var context: mach_port_context_t = 0
    let survived = mach_port_get_context(mach_task_self_, marker, &context) == KERN_SUCCESS && context == markerContext
    let outcome = callCollect(privileged: true, timeoutSeconds: 10)
    print("exec뒤시작=\(startedAt) 포트권한=\(survived ? "남음" : "사라짐") 새연결 \(outcome.line)")
    exit(outcome.exitCode)
}

func hold(seconds: Int) async throws -> Never {
    let connection = xpc_connection_create_mach_service(
        HaetaeXPC.machServiceName, nil, UInt64(XPC_CONNECTION_MACH_SERVICE_PRIVILEGED))
    let events = Atomic(0)
    xpc_connection_set_event_handler(connection) { _ in events.add(1, ordering: .relaxed) }
    xpc_connection_resume(connection)

    // libxpc는 첫 메시지 전에는 서비스를 찾지 않는다. mach 수준에서도 쥐어 보려고 send right를 직접 받아 둔다.
    var bootstrap = mach_port_t(MACH_PORT_NULL)
    var service = mach_port_t(MACH_PORT_NULL)
    var lookup = task_get_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, &bootstrap)
    if lookup == KERN_SUCCESS { lookup = bootstrap_look_up(bootstrap, HaetaeXPC.machServiceName, &service) }

    try await Task.sleep(for: .seconds(seconds))
    print("결과=붙잡음끝 초=\(seconds) look_up=\(lookup == KERN_SUCCESS ? "성공" : "실패(\(lookup))") xpc이벤트=\(events.load(ordering: .relaxed))")
    withExtendedLifetime(connection) {}
    exit(0)
}

let arguments = CommandLine.arguments.dropFirst()
func value(after flag: String) -> String? {
    arguments.firstIndex(of: flag).flatMap { arguments.index(after: $0) < arguments.endIndex ? arguments[arguments.index(after: $0)] : nil }
}

if let target = value(after: "--exec-swap") {
    execSwap(to: target)
} else if let marker = value(after: "--after-exec").flatMap(mach_port_name_t.init) {
    afterExec(marker: marker)
} else if let seconds = value(after: "--hold").flatMap(Int.init) {
    try await hold(seconds: seconds)
} else {
    let outcome = callCollect(privileged: !arguments.contains("--no-privileged"),
                              timeoutSeconds: value(after: "--timeout").flatMap(Int.init) ?? 10)
    print(outcome.line)
    exit(outcome.exitCode)
}
