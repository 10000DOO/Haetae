import AppKit
import HaetaeAppCore
import SwiftUI

/// 메뉴바 패널(R4, WO-53). 여기서는 조립만 한다 — 하위 뷰는 `AppState`·`ScanController`를 모르고 값만 받는다
/// (바뀐 값을 읽는 뷰만 다시 그리고, 저장소 밖에서 같은 파일로 화면을 그려 볼 수 있게).
struct PanelView: View {
    let state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PanelHeader(headline: headline, lastScan: state.scan?.lastReport?.finishedAt)
            // 승인 대기·미등록이면 스케줄러가 돌지 않는다 — 다음 검사와 "지금 검사"를 보이지 않는다(설계 리뷰 L1).
            if let scan = state.scan, scan.isStarted {
                NextScanView(phase: nextScan(scan))
            }
            PanelBanners(banners: banners) { perform($0) }
            if let scan = state.scan {
                RiskListView(risks: scan.risks, verified: scan.verifiedFingerprints, lastScan: scan.lastReport?.finishedAt)
            }
            PanelFooter(
                canScan: state.scan?.isStarted ?? false, paused: state.scan?.pausedUntil != nil, caption: caption,
                onScan: { state.scan?.scanNow() }, onPause: { state.scan?.pause(for: .seconds(3_600)) }, onResume: { state.scan?.resume() },
                onSettings: {
                    // Dock 아이콘이 없는 앱이라 앞으로 가져오지 않으면 설정 창이 다른 앱 뒤에 뜬다.
                    NSApp.activate()
                    openSettings()
                },
                onQuit: { state.quit() }
            )
        }
        .padding(14)
        .frame(width: 360)
        // 패널을 열 때마다 알림 설정을 다시 본다 — 시스템 설정에서 켜고 돌아오면 바로 맞게.
        .task { await state.scan?.refreshNotifications() }
    }

    private var headline: PanelHeadline {
        PanelHeadline(state: state.watchState, riskLevels: state.scan?.risks.filter(\.isRisk).map(\.level) ?? [])
    }

    private func nextScan(_ scan: ScanController) -> NextScanView.Phase {
        if scan.isScanning { return .scanning }
        if let until = scan.pausedUntil { return .paused(until: until) }
        if let at = scan.nextScanAt { return .scheduled(at: at, interval: scan.scanInterval / .seconds(1)) }
        return .notStarted
    }

    /// 판정 방식·패턴 버전·데몬 빌드(Q74 1번). WO-23은 "규칙 판정" 자리에 모델 이름·상태를 넣는다.
    private var caption: String? {
        guard let scan = state.scan, let report = scan.lastReport else { return nil }
        return "\(scan.judgeName) · 패턴 v\(report.patternVersion) · 데몬 빌드 \(report.daemonBuild)"
    }

    private var banners: [PanelBanner] {
        PanelBanner.list(
            needsInstall: state.needsInstall, daemon: state.daemonStatus, notificationsEnabled: state.scan?.notificationsEnabled ?? true,
            report: state.scan?.lastReport, problem: state.scan?.problem, recordRebuilt: state.scan?.recordRebuilt ?? false
        )
    }

    private func perform(_ action: PanelBanner.Action) {
        switch action {
        case .openLoginItems:
            state.openLoginItemsSettings()
        case .openNotificationSettings:
            Notifier.openSystemSettings()
        }
    }
}
