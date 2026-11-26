import HaetaeShared
import os

/// public으로 남기는 값은 checkID·건수·소요 시간·오류 코드·uid뿐이다. 경로·명령 출력·evidence·지문은 private 그대로 둔다 —
/// 다른 사용자가 `log show`로 볼 수 있다(T1).
enum ChecksLog {
    static let checks = Logger(subsystem: CodeRequirements.daemonIdentifier, category: "checks")
    static let ledger = Logger(subsystem: CodeRequirements.daemonIdentifier, category: "ledger")
    static let patterns = Logger(subsystem: CodeRequirements.daemonIdentifier, category: "patterns")
}
