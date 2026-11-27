import Foundation

/// 패널의 살펴볼 것(WO-53 3번). 어떤 배너를 어떤 순서로 띄울지는 여기서 정한다 — 화면은 그리기만(WO-53 0번, 설계 리뷰 L2).
public struct PanelBanner: Identifiable, Equatable, Sendable {
    /// 바로 할 수 있는 일(Q76).
    public enum Action: Equatable, Sendable {
        case openNotificationSettings
        case openLoginItems

        public var title: String {
            switch self {
            case .openNotificationSettings: "알림 켜기"
            case .openLoginItems: "열기"
            }
        }
    }

    public let id: String
    public let symbol: String
    public let text: String
    /// 탐지에서 온 글(검사 ID)이 들었다 — `Text(verbatim:)`로 그린다(D12).
    public let verbatim: Bool
    /// 빨강(못 보낸 건, 설치가 필요함). 아니면 주황.
    public let high: Bool
    public let action: Action?

    public init(id: String, symbol: String, text: String, verbatim: Bool = false, high: Bool = false, action: Action? = nil) {
        self.id = id
        self.symbol = symbol
        self.text = text
        self.verbatim = verbatim
        self.high = high
        self.action = action
    }

    /// 지금 띄울 배너. 순서: 설치·승인(감시를 시작하지 못함) → 알림 꺼짐 → 못 보낸 건 → 검사 공백 → 실패한 검사 → 저장·ack 실패 → 기록 재구성.
    public static func list(
        needsInstall: Bool, daemon: DaemonStatus, notificationsEnabled: Bool, report: ScanReport?, problem: ScanProblem?, recordRebuilt: Bool
    ) -> [PanelBanner] {
        var banners: [PanelBanner] = []
        if needsInstall {
            banners.append(PanelBanner(
                id: "install", symbol: "folder.badge.questionmark", text: "응용 프로그램 폴더에 설치한 뒤 실행하세요. 이 위치에서는 데몬을 등록하지 않아요.",
                high: true
            ))
        }
        if daemon == .requiresApproval {
            banners.append(PanelBanner(
                id: "approval", symbol: "person.badge.key", text: "시스템 설정의 로그인 항목에서 Haetae를 허용해 주세요.", action: .openLoginItems
            ))
        }
        if !notificationsEnabled {
            banners.append(PanelBanner(
                id: "notifications", symbol: "bell.slash", text: "시스템 설정에서 Haetae 알림을 켜 주세요.", action: .openNotificationSettings
            ))
        }
        if let report {
            if report.droppedFindings > 0 {
                banners.append(PanelBanner(
                    id: "dropped", symbol: "tray.full", text: "\(report.droppedFindings)건은 표시하지 못했어요. 다음 검사에서 이어서 받아요.", high: true
                ))
            }
            if let gap = report.scanGap {
                let text = gap < 60 ? "1분 미만 동안 검사하지 못했어요." : "\(Int(gap / 60))분 동안 검사하지 못했어요."
                banners.append(PanelBanner(id: "gap", symbol: "clock.badge.exclamationmark", text: text))
            }
            if !report.failedChecks.isEmpty {
                // 검사 ID는 데몬이 형식을 검증한 값이지만 보이는 글이라 verbatim으로.
                banners.append(PanelBanner(
                    id: "failed", symbol: "exclamationmark.triangle",
                    text: "검사 \(report.failedChecks.count)개가 실패했어요: \(report.failedChecks.joined(separator: ", "))", verbatim: true
                ))
            }
        }
        switch problem {
        case .storeFailed:
            banners.append(PanelBanner(id: "store", symbol: "externaldrive.badge.exclamationmark", text: "기록을 저장하지 못했어요. 다음 검사에서 다시 저장해요."))
        case .ackFailed:
            banners.append(PanelBanner(id: "ack", symbol: "arrow.triangle.2.circlepath", text: "데몬에 결과를 알리지 못했어요. 다음 검사에서 다시 알려요."))
        case nil:
            break
        }
        if recordRebuilt {
            banners.append(PanelBanner(id: "rebuilt", symbol: "doc.badge.clock", text: "Haetae 기록을 읽지 못해 데몬 기록으로 다시 만들었어요."))
        }
        return banners
    }

    /// 연결은 됐지만 살펴볼 것이 있다(`WatchState.attention`). 실패한 검사도 든다 — 배너가 "실패"인데 머리가 "이상 없음"이면 안 되고,
    /// 검사를 몰래 꺼 버리는 것(T12)이 머리·아이콘에서 드러나야 한다(WO-53 설계 리뷰 M1).
    public static func needsAttention(report: ScanReport?, problem: ScanProblem?, recordRebuilt: Bool) -> Bool {
        problem != nil || recordRebuilt
            || (report.map { $0.droppedFindings > 0 || $0.scanGap != nil || !$0.failedChecks.isEmpty } ?? false)
    }
}
