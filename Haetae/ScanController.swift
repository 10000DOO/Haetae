import AppKit
import Foundation
import HaetaeAppCore
import HaetaeShared
import Observation

/// 검사 쪽 상태와 조작(위험 목록, 마지막·다음 검사, 일시정지, 알림). 데몬 수명(등록·승인·재실행·종료)은 `AppState`가 맡는다 —
/// 검사 결과 중 연결에 관한 것만 `onConnected`·`onCollectFailure`로 넘긴다.
@Observable
@MainActor
final class ScanController {
    /// 아직 있는 위험(검사마다 기록에서 다시 읽는다).
    private(set) var risks: [Risk]
    /// `risks` 중 데몬 응답으로 확인한 지문. `risks`와 같은 때에만 바꾼다 — 따로 읽으면 맞추기 뒤·다시 읽기 전 사이에 파일에 심은
    /// 옛 증거가 "확인됨"으로 보일 수 있다(WO-53 보안 리뷰 L1).
    private(set) var verifiedFingerprints: Set<String> = []
    private(set) var lastReport: ScanReport?
    private(set) var problem: ScanProblem?
    private(set) var nextScanAt: Date?
    private(set) var pausedUntil: Date?
    private(set) var scanInterval: Duration
    /// 알림이 꺼져 있으면 메뉴바 아이콘으로 경고한다(D28). 검사마다 다시 본다.
    private(set) var notificationsEnabled = true
    /// 기록 파일을 읽지 못했거나 데몬 요약으로 다시 만들었다(Q72). 이번 실행 동안 패널에 남긴다.
    private(set) var recordRebuilt = false
    /// 판정 방식 이름(패널 맨 아래 줄·설정 정보 탭). WO-22·23이 모델 판정을 붙이면 여기만 바꾼다(설계 리뷰 L4).
    var judgeName: String { "규칙 판정" }
    /// 검사가 돌고 있다(Q77 — 패널 "검사하고 있어요").
    private(set) var isScanning = false
    /// 스케줄러가 돌고 있다(데몬 승인 확인 뒤 `start`). 아니면 "지금 검사"가 아무 일도 하지 않는다(설계 리뷰 L1).
    private(set) var isStarted = false

    /// 연결은 됐지만 살펴볼 것이 있다(메뉴바 아이콘·패널 머리, `WatchState.attention`).
    var needsAttention: Bool {
        PanelBanner.needsAttention(report: lastReport, problem: problem, recordRebuilt: recordRebuilt)
    }

    @ObservationIgnored var onConnected: ((_ daemonBuild: Int) -> Void)?
    @ObservationIgnored var onCollectFailure: ((any Error) -> Void)?

    @ObservationIgnored private let store: RiskStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let notifier: Notifier
    @ObservationIgnored private var scheduler: ScanScheduler?
    /// 알림이 꺼져 있던 동안 못 보낸 것. 켜지면 한 번 보낸다 — 첫 실행에 권한을 정하기 전 첫 검사의 알림이 사라지지 않게.
    @ObservationIgnored private var missedRiskAlert = false
    @ObservationIgnored private var missedRebuildAlert = false
    @ObservationIgnored private var rebuildNotified = false
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    init(source: any FindingSource, store: RiskStore = RiskStore(), settings: AppSettings = AppSettings(), notifier: Notifier = Notifier()) {
        self.store = store
        self.settings = settings
        self.notifier = notifier
        let active = store.activeRisks
        risks = active
        verifiedFingerprints = Set(active.map(\.fingerprint).filter(store.isVerified))
        scanInterval = settings.scanInterval
        let pipeline = ScanPipeline(
            source: source, store: store, judgeProvider: { RuleOnlyJudge() },
            notify: { [weak self] count, _ in await self?.alertRisks(count: count) },
            report: { [weak self] in self?.handle($0) }
        )
        scheduler = ScanScheduler(
            settings: settings,
            run: { [weak self] in
                self?.isScanning = true
                await pipeline.run()
                self?.isScanning = false
            },
            onPauseChange: { [weak self] in self?.refreshSettings() },
            onSchedule: { [weak self] wait in self?.nextScanAt = Date().addingTimeInterval(wait / .seconds(1)) }
        )
    }

    /// 앱이 뜰 때 한 번. 알림 권한을 묻고 지금 상태를 본다.
    func setUp() async {
        await notifier.setUp()
        if store.loadFailed { await noteRecordRebuilt() }
        await refreshNotifications()
        // 시스템 설정에서 알림을 켜고 돌아오면 앱이 앞으로 온다 — 열려 있던 설정 창·패널은 다시 나타나는 게 아니라 `.task`가 돌지
        // 않으니 여기서 다시 읽는다(WO-55 설계 재리뷰 L1).
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
            [weak self] _ in Task { @MainActor in await self?.refreshNotifications() }
        }
    }

    /// 데몬 승인 확인이 끝난 뒤 `AppState`가 부른다. 첫 검사가 곧 연결 확인이다.
    func start() {
        scheduler?.start()
        isStarted = scheduler != nil
    }

    /// 앱을 끝내기 전에 부른다 — 데몬에 "사용자 종료"를 알린 뒤 새 검사가 다시 연결하면 비정상 종료로 적힌다.
    func stop() {
        scheduler?.stop()
        isStarted = false
    }

    func scanNow() {
        scheduler?.scanNow()
    }

    /// 연결이 끊겼다. 쉬는 중이면 검사하지 않는다(사용자가 쉬게 해 둔 동안 데몬이 다시 뜰 때마다 돌지 않게).
    func connectionLost() {
        guard settings.pausedUntil == nil else { return }
        scheduler?.scanNow()
    }

    func pause(for duration: Duration) {
        scheduler?.pause(for: duration)
        // 늘리기는 쉬는 상태가 그대로라 스케줄러가 알리지 않는다 — 끝 시각은 여기서 다시 읽는다.
        refreshSettings()
    }

    func resume() {
        scheduler?.resume()
        refreshSettings()
    }

    /// 범위(5~60분)를 벗어나면 false.
    @discardableResult
    func setScanInterval(_ interval: Duration) -> Bool {
        defer { refreshSettings() }
        return scheduler?.setInterval(interval) ?? false
    }

    /// 파이프라인의 결과를 상태로 바꾸는 유일한 곳(WO-14 0번).
    private func handle(_ result: Result<ScanReport, ScanFailure>) {
        // 실패해도 해결·맞추기는 반영됐을 수 있어 늘 다시 읽는다.
        risks = store.activeRisks
        verifiedFingerprints = Set(risks.map(\.fingerprint).filter(store.isVerified))
        switch result {
        case .success(let report):
            accept(report)
            problem = nil
        case .failure(.store(_, let report)):
            accept(report)
            problem = .storeFailed
        case .failure(.ack(_, let report)):
            accept(report)
            problem = .ackFailed
        case .failure(.collect(let error)):
            onCollectFailure?(error)
        }
        Task { await refreshNotifications() }
    }

    private func accept(_ report: ScanReport) {
        lastReport = report
        onConnected?(report.daemonBuild)
        if report.restored > 0 { Task { await noteRecordRebuilt() } }
    }

    /// 늘 보낸다(스타일이 "없음"이어도 알림 센터에 남는다). 등록하지 못했으면(권한 없음, 알림 서버 응답 없음 — 5초 상한) 놓친 것으로
    /// 남겨, 알림이 켜지면 한 번 다시 보낸다. 앞서 놓친 것이 있으면 아직 있는 위험 전체 수로 한 번만 보낸다(두 번 이어서 가지 않게).
    /// 권한 확인(`isEnabled`)은 여기서 하지 않는다 — 알림 서버가 멈추면 그것도 돌아오지 않아 검사가 멈춘다.
    private func alertRisks(count: Int) async {
        let total = missedRiskAlert ? max(count, store.activeRisks.filter(\.isRisk).count) : count
        missedRiskAlert = false
        if !(await notifier.notifyRisks(count: total)) { missedRiskAlert = true }
    }

    /// 실행마다 알림은 한 번만(Q72).
    private func noteRecordRebuilt() async {
        recordRebuilt = true
        guard !rebuildNotified else { return }
        // 기다리기 전에 세운다 — 시작할 때와 첫 검사가 겹쳐 두 번 보내지 않게.
        rebuildNotified = true
        guard await notifier.notifyRecordRebuilt() else {
            rebuildNotified = false
            missedRebuildAlert = true
            return
        }
    }

    /// 알림이 꺼졌다 켜지면 그동안 못 보낸 알림을 한 번 보낸다(아직 있는 위험 수 기준).
    /// 패널·설정 창이 열릴 때도 부른다 — 시스템 설정에서 알림을 켜고 돌아오면 다음 검사(최대 60분)까지 기다리지 않게(WO-55 설계 리뷰 L3).
    func refreshNotifications() async {
        notificationsEnabled = await notifier.isEnabled()
        guard notificationsEnabled else { return }
        if missedRiskAlert {
            missedRiskAlert = false
            let count = risks.filter(\.isRisk).count
            if count > 0, !(await notifier.notifyRisks(count: count)) { missedRiskAlert = true }
        }
        if missedRebuildAlert {
            missedRebuildAlert = false
            await noteRecordRebuilt()
        }
    }

    private func refreshSettings() {
        pausedUntil = settings.pausedUntil
        scanInterval = settings.scanInterval
    }
}
