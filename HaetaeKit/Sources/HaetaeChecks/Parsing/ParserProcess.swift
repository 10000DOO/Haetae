import Foundation
import HaetaeShared

/// 공격자가 쓸 수 있는 파일을 해석하는 전용 프로세스(Q42·Q47). 데몬이 자기 실행 파일을 `--parse <형식>`으로 다시 띄운다.
/// 해석기가 뚫려도 할 수 있는 일이 적게, 입력을 읽기 전에 nobody로 내려가고 자원을 제한한다.
public enum ParserProcess {
    /// 종료 코드(sysexits). 뚫린 자식은 종료 코드를 마음대로 고를 수 있으니 데몬 쪽(WO-48)은 0인지만 믿는다.
    public static let exitUsage: Int32 = 64
    public static let exitBadInput: Int32 = 65
    public static let exitNoPermission: Int32 = 77

    /// stdin의 내용을 해석해 `ParsedValue`를 JSON으로 stdout에 쓰고 끝낸다. 결과는 stdout으로만 나간다.
    public static func run(arguments: [String]) -> Never {
        // 순서를 바꾸지 않는다 — 권한과 자원 상한이 먼저, 공격자 데이터는 그 뒤.
        guard dropPrivileges(), limitResources() else { exit(exitNoPermission) }
        guard arguments.count == 1, let format = ParseFormat(rawValue: arguments[0]) else { exit(exitUsage) }
        do {
            var input = Data()
            try readChunks(STDIN_FILENO) {
                input.append(contentsOf: $0)
                if input.count > ParserLimits.maxInputBytes { throw ParseFailure.limit }
            }
            try FileHandle.standardOutput.write(contentsOf: try respond(input, format: format))
            exit(0)
        } catch {
            exit(exitBadInput)
        }
    }

    /// 해석 → 인코딩 → 출력 상한. 권한·입출력과 분리해 테스트한다.
    /// 데몬(root)에서 부르면 Q42 격리를 통째로 우회하므로 테스트에서만 직접 부른다.
    static func respond(_ input: Data, format: ParseFormat) throws -> Data {
        let output = try JSONWire.encode(try parse(input, format: format))
        // 문자열 이스케이프로 늘어난 분량은 인코딩한 뒤에야 안다.
        guard output.count <= ParserLimits.maxOutputBytes else { throw ParseFailure.limit }
        return output
    }

    static func parse(_ data: Data, format: ParseFormat) throws -> ParsedValue {
        let object: Any = switch format {
        // format 포인터 자리에 nil만 넘기므로 안전하다.
        case .plist: try unsafe PropertyListSerialization.propertyList(from: data, format: nil)
        }
        var budget = Budget()
        return try convert(object, depth: 1, budget: &budget)
    }

    enum ParseFailure: Error {
        case limit
        case unsupported
    }

    /// 바이너리 plist는 같은 객체를 여러 번 가리킬 수 있어, 입력이 작아도 펼친 결과가 커진다. 인코딩 전에 센다.
    private struct Budget {
        var nodes = 0
        var bytes = 0

        mutating func charge(nodes addedNodes: Int = 0, bytes addedBytes: Int) throws {
            nodes += addedNodes
            bytes += addedBytes
            guard nodes <= ParserLimits.maxNodes, bytes <= ParserLimits.maxOutputBytes else { throw ParseFailure.limit }
        }
    }

    private static func convert(_ object: Any, depth: Int, budget: inout Budget) throws -> ParsedValue {
        // 8 = 태그 객체 하나(`{"s":…}`)의 최소 길이.
        try budget.charge(nodes: 1, bytes: 8)
        guard depth <= ParserLimits.maxDepth else { throw ParseFailure.limit }
        switch object {
        case let value as String:
            try budget.charge(bytes: encodedLength(value))
            return .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
            if CFNumberIsFloatType(value) { return .double(value.doubleValue) }
            // Int64를 넘는 부호 없는 정수는 실수로 담는다(값이 정확하지 않을 수 있다).
            return Int64(value.stringValue).map(ParsedValue.int) ?? .double(value.doubleValue)
        case let value as Data:
            try budget.charge(bytes: value.count / 3 * 4 + 4)
            return .data(value)
        case let value as Date:
            return .date(value)
        case let value as [Any]:
            return .array(try value.map { try convert($0, depth: depth + 1, budget: &budget) })
        case let value as NSDictionary:
            guard let dictionary = value as? [String: Any] else { throw ParseFailure.unsupported }
            // 정규 동치 키(é와 e+◌́)는 Swift String에서 같은 키가 되어 하나가 사라진다 — 다른 사전을 보지 않게 거부한다.
            guard dictionary.count == value.count else { throw ParseFailure.unsupported }
            try budget.charge(bytes: dictionary.keys.reduce(0) { $0 + encodedLength($1) + 3 })
            return .object(try dictionary.mapValues { try convert($0, depth: depth + 1, budget: &budget) })
        default:
            throw ParseFailure.unsupported
        }
    }

    /// JSON으로 적었을 때의 길이. 제어 문자는 `\u00XX`(6바이트), `"`·`\`는 2바이트로 늘어난다.
    private static func encodedLength(_ string: String) -> Int {
        string.utf8.reduce(0) { $0 + ($1 < 0x20 ? 6 : $1 == 0x22 || $1 == 0x5C ? 2 : 1) }
    }

    /// root면 nobody(uid·gid -2)로 영구히 내린다. root가 아니면 낮출 권한이 없으니 그대로 둔다(테스트).
    /// root 실측 도구가 같은 소스로 이 함수를 부르려고 internal이다 — 검사에서 부르지 않는다.
    static func dropPrivileges() -> Bool {
        let nobody = uid_t(bitPattern: -2)
        let nobodyGroup = gid_t(bitPattern: -2)
        if getuid() == 0 || geteuid() == 0 {
            var groups = [nobodyGroup]
            guard unsafe setgroups(1, &groups) == 0, setgid(nobodyGroup) == 0, setuid(nobody) == 0 else { return false }
            var current = [gid_t](repeating: 0, count: 16)
            guard getuid() == nobody, geteuid() == nobody, getgid() == nobodyGroup, getegid() == nobodyGroup,
                  unsafe getgroups(Int32(current.count), &current) == 1, current[0] == nobodyGroup
            else { return false }
        }
        // root가 아니었어도 확인한다 — 실제·저장된 uid가 0이면 여기서 걸린다.
        return setuid(0) != 0 && setgid(0) != 0
    }

    /// 뚫렸을 때 할 수 있는 일을 줄인다: CPU 시간, 파일 쓰기, core 파일, fork(`RLIMIT_NPROC` — exec는 못 막는다).
    /// fd 상한 3은 상속된 fd가 없다는 것만 보장한다 — 0·1·2 중 하나를 닫으면 새 파일·소켓을 열 수 있어 경계가 아니다(Q48).
    /// 메모리 상한은 이 OS에서 `setrlimit`가 받지 않아 출력 크기 예산으로 대신한다.
    static func limitResources() -> Bool {
        let limits: [(Int32, rlim_t)] = [(RLIMIT_CPU, 10), (RLIMIT_FSIZE, 0), (RLIMIT_NOFILE, 3), (RLIMIT_CORE, 0), (RLIMIT_NPROC, 0)]
        return limits.allSatisfy { resource, value in
            var limit = rlimit(rlim_cur: value, rlim_max: value)
            return unsafe setrlimit(resource, &limit) == 0
        }
    }
}
