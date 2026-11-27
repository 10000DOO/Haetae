import Foundation
import HaetaeShared

/// 지금 감시 상태(WO-53 0번). 메뉴바 아이콘(`StatusIcon`)과 패널 머리(`PanelHeadline`)가 둘 다 이것에서 나온다 — 우선순위를 여기
/// 한 곳에서만 정해 아이콘과 패널이 다른 말을 하지 않게. 위험은 따로 받는다(이 상태 위에 겹쳐 보인다).
/// 우선순위: 데몬을 믿을 수 없음 → 감시가 돌지 않음(미등록·승인 대기 포함) → 알림 꺼짐 → 일시정지 → 연결 중 → 살펴볼 것 → 정상.
public enum WatchState: Equatable, Sendable {
    case untrusted(DaemonStatus)
    case notRunning(DaemonStatus)
    case notificationsOff
    case paused
    case connecting
    /// 연결됐고 살펴볼 것(검사 공백·못 보낸 건·저장/ack 실패·기록 재구성)이 있다.
    case attention
    case normal

    public init(daemon: DaemonStatus, notificationsOn: Bool, paused: Bool, needsAttention: Bool) {
        // 모든 case를 적는다 — 새 상태를 더하면(WO-43) 컴파일러가 이곳을 알려 준다.
        switch daemon {
        case .verificationFailed, .rolledBack, .identityError:
            self = .untrusted(daemon)
        case .notRegistered, .requiresApproval, .registrationFailed, .relaunchNeeded, .staleDaemon, .noResponse, .malformedReply, .daemonError:
            self = .notRunning(daemon)
        case .connecting, .connected:
            if !notificationsOn {
                self = .notificationsOff
            } else if paused {
                self = .paused
            } else if case .connected = daemon {
                self = needsAttention ? .attention : .normal
            } else {
                self = .connecting
            }
        }
    }

    /// 위험 표시가 이 상태를 가려도 된다(연결 중·살펴볼 것·정상). 그보다 높은 상태는 위험이 있어도 그 모양을 남긴다 —
    /// 감시가 멈춘 것·쉬는 것이 위험에 가려지지 않게(WO-14 2단계 재리뷰).
    public var isCalm: Bool {
        switch self {
        case .connecting, .attention, .normal: true
        case .untrusted, .notRunning, .notificationsOff, .paused: false
        }
    }
}

/// 메뉴바 아이콘(WO-14 2번, D28). 위험이 있으면 빨강이다 — `isCalm`이면 위험 아이콘으로, 아니면 그 모양 그대로 빨강으로 한다.
public struct StatusIcon: Equatable, Sendable {
    public let symbol: String
    public let red: Bool
    /// 접근성 이름(VoiceOver).
    public let label: String

    public init(daemon: DaemonStatus, hasRisk: Bool, notificationsOn: Bool, paused: Bool, needsAttention: Bool) {
        self.init(state: WatchState(daemon: daemon, notificationsOn: notificationsOn, paused: paused, needsAttention: needsAttention), hasRisk: hasRisk)
    }

    public init(state: WatchState, hasRisk: Bool) {
        let base: (symbol: String, label: String) = switch state {
        case .untrusted: ("xmark.shield", "데몬을 믿을 수 없음")
        case .notRunning(.notRegistered): ("shield.slash", "감시가 돌지 않음, 데몬 미등록")
        case .notRunning(.requiresApproval): ("shield.slash", "감시가 돌지 않음, 승인 필요")
        case .notRunning: ("shield.slash", "감시가 돌지 않음")
        case .notificationsOff: ("bell.slash", "알림 꺼짐")
        case .paused: ("pause.circle", "일시정지")
        case .connecting: ("shield.lefthalf.filled", "연결 중")
        case .attention: ("exclamationmark.shield", "살펴볼 것 있음")
        case .normal: ("shield", "정상")
        }
        if !hasRisk {
            (symbol, red, label) = (base.symbol, false, base.label)
        } else if state.isCalm {
            (symbol, red, label) = ("exclamationmark.shield.fill", true, "보안 위험 있음")
        } else {
            (symbol, red, label) = (base.symbol, true, "보안 위험 있음, \(base.label)")
        }
    }
}

/// 패널 머리(WO-53 1번): 기호·결론 한 줄·설명·색 역할. 화면은 그리기만 한다.
public struct PanelHeadline: Equatable, Sendable {
    /// 색 역할. 브랜드 색은 정상일 때만 — 상태 색(빨강·주황)과 섞지 않는다(Q79).
    public enum Tone: Equatable, Sendable {
        case brand, danger, warning, neutral
    }

    public let symbol: String
    public let title: String
    public let detail: String?
    public let tone: Tone

    /// - Parameter riskLevels: 아직 있는 위험(`isRisk`)의 수준.
    public init(state: WatchState, riskLevels: [RiskLevel]) {
        let base: (symbol: String, title: String, detail: String?, tone: Tone) = switch state {
        case .untrusted(let daemon): ("xmark.shield", "데몬을 믿을 수 없어요", daemon.detail, .danger)
        // 승인 대기는 처음 실행 때 거치는 단계라 빨강으로 놀라게 하지 않는다(설계 리뷰 의견). 할 일은 아래 배너에.
        case .notRunning(.requiresApproval): ("shield.slash", "승인이 필요해요", "허용하면 감시를 시작해요", .warning)
        case .notRunning(let daemon): ("shield.slash", "감시가 멈췄어요", daemon.detail, .danger)
        case .notificationsOff: ("bell.slash", "알림이 꺼져 있어요", "위험을 찾아도 알림이 오지 않아요", .warning)
        case .paused: ("pause.circle", "일시정지 중", "검사를 잠시 쉬고 있어요", .neutral)
        case .connecting: ("shield.lefthalf.filled", "연결 중", "데몬과 연결하고 있어요", .neutral)
        case .attention: ("exclamationmark.shield", "살펴볼 것이 있어요", "아래 안내를 확인하세요", .warning)
        case .normal: ("checkmark.shield", "보호 중", "이상 없음", .brand)
        }
        guard !riskLevels.isEmpty else {
            (symbol, title, detail, tone) = base
            return
        }
        let counts = Self.counts(riskLevels)
        if state.isCalm {
            (symbol, title, detail, tone) = ("exclamationmark.shield.fill", "위험 \(riskLevels.count)건 발견", counts, .danger)
        } else {
            // 더 높은 상태는 그 이유를 남긴다(감시가 왜 멈췄는지가 먼저) — 위험 수는 뒤에, 자세한 건 아래 목록에.
            (symbol, title, detail, tone) = (base.symbol, base.title, [base.detail, "위험 \(riskLevels.count)건"].compactMap(\.self).joined(separator: " · "), .danger)
        }
    }

    /// "높음 1 · 중간 2" — 0건인 수준은 뺀다.
    static func counts(_ levels: [RiskLevel]) -> String {
        [(RiskLevel.high, "높음"), (.medium, "중간"), (.low, "낮음")]
            .compactMap { level, name in
                let count = levels.count { $0 == level }
                return count > 0 ? "\(name) \(count)" : nil
            }
            .joined(separator: " · ")
    }
}

/// 패널의 시간 글(WO-53). 화면 글이 한국어라 시각도 한국어로 고정한다 — 앱 현지화가 영어뿐이라 `Locale.current`는 "11:38 AM"이 된다.
public enum PanelTime {
    private static let korean = Locale(identifier: "ko_KR")

    /// "방금", "3분 전", "2시간 전", 하루가 넘으면 "2026. 11. 26. 오후 3:10" 같은 글.
    public static func ago(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        return switch seconds {
        case ..<60: "방금"
        case ..<3_600: "\(Int(seconds / 60))분 전"
        case ..<86_400: "\(Int(seconds / 3_600))시간 전"
        default: date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(korean))
        }
    }

    /// "곧", "12분", "1시간 5분" — 다음 검사까지 남은 시간. 가까운 분으로 반올림한다 — 올림이면 15분 주기를 막 시작했을 때
    /// "16분"으로 보였다(2026-11-27 사용자 화면).
    public static func remaining(until date: Date, now: Date) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded())
        return switch minutes {
        case ..<1: "곧"
        case ..<60: "\(minutes)분"
        default: minutes % 60 == 0 ? "\(minutes / 60)시간" : "\(minutes / 60)시간 \(minutes % 60)분"
        }
    }

    /// "오전 11:38".
    public static func clock(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(korean))
    }

    /// "11월 27일 오전 11:38".
    public static func dateTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(korean))
    }
}
