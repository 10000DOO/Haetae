import Foundation
import HaetaeShared

/// 앱 `DaemonClient`가 던지는 연결 오류(재시도·재실행 판단은 `ReconnectPolicy`).
public enum DaemonClientError: Error, Sendable {
    /// 디스크의 앱이나 데몬이 더 새 빌드다. 앱이 다시 떠야 한다(D20).
    case needsRelaunch
    /// Debug에서만: 데몬이 더 옛 빌드다.
    case staleDaemon
    /// 다시 시도해도 데몬이 서명 요구사항을 통과하지 못했다.
    case verificationFailed
    case noResponse
    case timeout
}

/// 데몬 연결 상태. 원인마다 따로 둔다 — 같은 문구로 보이면 무해한 것과 높은 것(되돌린 빌드)을 구분하지 못한다(WO-14 0번).
public enum DaemonStatus: Equatable, Sendable {
    case notRegistered
    case requiresApproval
    case registrationFailed
    /// 앱의 서명·Info.plist가 맞지 않아 데몬 요구사항을 만들지 못했다(`AppIdentity`).
    case identityError
    case connecting
    case connected(build: Int)
    case verificationFailed
    /// 디스크에 새 빌드가 있는데 스스로 다시 뜰 수 없다(launchd가 띄운 인스턴스가 아니거나 횟수 초과) — 사용자가 다시 실행해야 한다.
    case relaunchNeeded
    /// Debug: 등록된 데몬(root 사본)이 이 앱보다 옛 빌드다.
    case staleDaemon
    /// 데몬이 되돌린 빌드라 모든 요청을 거부한다(D20).
    case rolledBack
    case noResponse
    case malformedReply
    case daemonError(code: Int)
}

extension DaemonStatus {
    /// 감시가 돌지 않는 문제라 사용자가 봐야 한다. 모든 case를 적는다 — 새 상태를 더하면(WO-43) 컴파일러가 이곳을 알려 준다.
    public var isProblem: Bool {
        switch self {
        case .notRegistered, .requiresApproval, .connecting, .connected: false
        case .registrationFailed, .identityError, .verificationFailed, .relaunchNeeded, .staleDaemon, .rolledBack, .noResponse, .malformedReply,
             .daemonError: true
        }
    }
}

/// 메뉴바 아이콘(WO-14 2번, D28). 우선순위: 데몬을 믿을 수 없음 → 감시가 돌지 않음(미등록·승인 대기 포함) → 알림 꺼짐 → 일시정지 →
/// 연결 중 → 살펴볼 것 → 정상. 위험이 있으면 빨강이다 — 연결 중·살펴볼 것·정상이면 위험 아이콘으로, 그보다 높은 상태면 그 모양 그대로
/// 빨강으로 한다(위험에 가려지지 않게, 재리뷰 두 리뷰 L).
public struct StatusIcon: Equatable, Sendable {
    public let symbol: String
    public let red: Bool
    /// 접근성 이름(VoiceOver).
    public let label: String

    public init(daemon: DaemonStatus, hasRisk: Bool, notificationsOn: Bool, paused: Bool, needsAttention: Bool) {
        // 모든 case를 적는다 — 새 상태를 더하면(WO-43) 컴파일러가 이곳을 알려 준다.
        let base: (symbol: String, label: String)
        var calm = false
        switch daemon {
        case .verificationFailed, .rolledBack, .identityError: base = ("xmark.shield", "데몬을 믿을 수 없음")
        case .notRegistered: base = ("shield.slash", "감시가 돌지 않음, 데몬 미등록")
        case .requiresApproval: base = ("shield.slash", "감시가 돌지 않음, 승인 필요")
        case .registrationFailed, .relaunchNeeded, .staleDaemon, .noResponse, .malformedReply, .daemonError: base = ("shield.slash", "감시가 돌지 않음")
        case .connecting, .connected:
            if !notificationsOn { base = ("bell.slash", "알림 꺼짐") }
            else if paused { base = ("pause.circle", "일시정지") }
            else {
                calm = true
                if case .connected = daemon { base = needsAttention ? ("exclamationmark.shield", "살펴볼 것 있음") : ("shield", "정상") }
                else { base = ("shield.lefthalf.filled", "연결 중") }
            }
        }
        if !hasRisk {
            (symbol, red, label) = (base.symbol, false, base.label)
        } else if calm {
            (symbol, red, label) = ("exclamationmark.shield.fill", true, "보안 위험 있음")
        } else {
            (symbol, red, label) = (base.symbol, true, "보안 위험 있음, \(base.label)")
        }
    }
}

/// 수집은 됐는데 결과를 끝까지 처리하지 못했다. 연결 상태와 따로 둔다 — 다음 검사에서 다시 저장·ack한다.
public enum ScanProblem: Equatable, Sendable {
    /// 기록을 쓰지 못해 ack하지 않았다(D24). 알림은 갔다.
    case storeFailed
    case ackFailed
}

/// 수집 실패에 앱이 할 일(WO-14 0번 — 판단을 한 곳에 두고 `swift test`로 지킨다).
public enum CollectFailureAction: Equatable, Sendable {
    /// 다시 뜬다(D20).
    case relaunch
    /// 무해하다(이 사용자의 검사가 막 돌았다 — `DaemonClient`가 한 번 기다린 뒤다). 다음 주기에 다시 한다.
    case ignore
    case show(DaemonStatus)

    public init(_ error: any Error) {
        self = switch error {
        case DaemonClientError.needsRelaunch: .relaunch
        case HaetaeXPCError.rateLimited: .ignore
        case DaemonClientError.verificationFailed: .show(.verificationFailed)
        case DaemonClientError.staleDaemon: .show(.staleDaemon)
        case HaetaeXPCError.rolledBack: .show(.rolledBack)
        case let error as HaetaeXPCError: .show(.daemonError(code: error.rawValue))
        case is WireValidationError, is DecodingError: .show(.malformedReply)
        default: .show(.noResponse)
        }
    }
}
