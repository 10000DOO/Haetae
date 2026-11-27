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
    private(set) var lastReport: ScanReport?
    private(set) var problem: ScanProblem?
    private(set) var nextScanAt: Date?
    private(set) var pausedUntil: Date?
    private(set) var scanInterval: Duration
    /// 알림이 꺼져 있으면 메뉴바 아이콘으로 경고한다(D28). 검사마다 다시 본다.
    private(set) var notificationsEnabled = true
    /// 기록 파일을 읽지 못했거나 데몬 요약으로 다시 만들었다(Q72). 이번 실행 동안 패널에 남긴다.
    private(set) var recordRebuilt = false

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

    init(source: any FindingSource, store: RiskStore = RiskStore(), settings: AppSettings = AppSettings(), notifier: Notifier = Notifier()) {
        self.store = store
        self.settings = settings
        self.notifier = notifier
        risks = store.activeRisks
        scanInterval = settings.scanInterval
        let pipeline = ScanPipeline(
            source: source, store: store, judgeProvider: { RuleOnlyJudge() },
            notify: { [weak self] count, _ in await self?.alertRisks(count: count) },
            report: { [weak self] in self?.handle($0) }
        )
        scheduler = ScanScheduler(
            settings: settings, run: { await pipeline.run() },
            onPauseChange: { [weak self] in self?.refreshSettings() },
            onSchedule: { [weak self] wait in self?.nextScanAt = Date().addingTimeInterval(wait / .seconds(1)) }
        )
    }

    /// 앱이 뜰 때 한 번. 알림 권한을 묻고 지금 상태를 본다.
    func setUp() async {
        await notifier.setUp()
        if store.loadFailed { await noteRecordRebuilt() }
        await refreshNotifications()
    }

    /// 데몬 승인 확인이 끝난 뒤 `AppState`가 부른다. 첫 검사가 곧 연결 확인이다.
    func start() {
        scheduler?.start()
    }

    /// 앱을 끝내기 전에 부른다 — 데몬에 "사용자 종료"를 알린 뒤 새 검사가 다시 연결하면 비정상 종료로 적힌다.
    func stop() {
        scheduler?.stop()
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

    /// 파일에서 읽고 아직 데몬 응답으로 확인 못 한 항목이면 false — 패널은 "확인 전"으로 보인다.
    func isVerified(_ risk: Risk) -> Bool {
        store.isVerified(risk.fingerprint)
    }

    /// 파이프라인의 결과를 상태로 바꾸는 유일한 곳(WO-14 0번).
    private func handle(_ result: Result<ScanReport, ScanFailure>) {
        // 실패해도 해결·맞추기는 반영됐을 수 있어 늘 다시 읽는다.
        risks = store.activeRisks
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
    private func refreshNotifications() async {
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
