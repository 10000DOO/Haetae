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
    /// 사람이 읽는 한 줄(패널 머리 설명, WO-53). 모든 case를 적는다.
    public var detail: String {
        switch self {
        case .notRegistered: "데몬이 등록되지 않았어요"
        case .requiresApproval: "시스템 설정에서 승인이 필요해요"
        case .registrationFailed: "데몬을 등록하지 못했어요"
        case .identityError: "앱 서명을 확인하지 못했어요"
        case .connecting: "데몬과 연결하고 있어요"
        case .connected(let build): "연결됨 (빌드 \(build))"
        case .verificationFailed: "데몬 서명 검증에 실패했어요"
        case .relaunchNeeded: "업데이트됐어요. Haetae를 다시 실행하세요"
        case .staleDaemon: "등록된 데몬이 옛 빌드예요"
        case .rolledBack: "데몬이 옛 빌드로 되돌려져 모든 요청을 거부해요"
        case .noResponse: "데몬이 응답하지 않아요"
        case .malformedReply: "데몬 응답 형식이 맞지 않아요"
        case .daemonError(let code): "데몬 오류 (코드 \(code))"
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
