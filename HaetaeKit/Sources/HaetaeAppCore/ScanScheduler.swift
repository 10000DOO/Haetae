import Foundation

/// 검사를 주기마다 돌린다(WO-13 4번). 주기·일시정지의 주인은 `AppSettings`다 — 바꾸는 쪽(UI)은 이것을 거쳐 쓰고, 이것이 바로 깨어나
/// 다음 검사 시각을 다시 정한다(잠들 때만 읽으면 일시정지 끝까지 자는 동안 재개·주기 단축을 모른다).
@MainActor
public final class ScanScheduler {
    private let settings: AppSettings
    private let run: () async -> Void
    private let onPauseChange: () -> Void
    private let onSchedule: (_ wait: Duration) -> Void
    private let clock: () -> ContinuousClock.Instant
    private let sleep: (Duration) async throws -> Void
    private var loop: Task<Void, Never>?
    private var lastRun: ContinuousClock.Instant?
    /// `start()` 뒤에만 돈다 — 승인 전에 설정을 바꿨다고 검사가 시작되지 않게(WO-14 "승인 뒤 start").
    private var started = false
    /// 마지막으로 알린 일시정지 상태. 검사 도중에 끝난 것도 알리게 매번 견준다.
    private var pauseShown = false

    /// - Parameters:
    ///   - run: 검사 한 번(`ScanPipeline.run`). 겹쳐 부르면 파이프라인이 합친다.
    ///   - onPauseChange: 일시정지가 시작·끝났다(저절로 끝난 것, 검사 도중 끝난 것 포함) — 아이콘을 제때 바꾸게.
    ///   - onSchedule: 다음 검사(쉬는 중이면 일시정지가 끝나는 때)까지 잠들기 직전에 남은 시간 — 패널의 "다음 검사".
    ///   - clock, sleep: 테스트에서 주입한다. 잠자기를 세는 시계라 맥이 깨어난 뒤 밀린 검사를 바로 한다.
    public init(
        settings: AppSettings, run: @escaping () async -> Void, onPauseChange: @escaping () -> Void = {},
        onSchedule: @escaping (_ wait: Duration) -> Void = { _ in },
        clock: @escaping () -> ContinuousClock.Instant = { .now },
        sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.settings = settings
        self.run = run
        self.onPauseChange = onPauseChange
        self.onSchedule = onSchedule
        self.clock = clock
        self.sleep = sleep
    }

    /// 앱이 뜬 직후 한 번 돌고 주기를 탄다.
    public func start() {
        started = true
        restart(runNow: true)
    }

    /// 일시정지 중에도 한 번 돈다(사용자가 누른 것이다). 일시정지는 그대로다.
    public func scanNow() {
        restart(runNow: true)
    }

    @discardableResult
    public func setInterval(_ interval: Duration) -> Bool {
        guard settings.setScanInterval(interval) else { return false }
        restart(runNow: false)
        return true
    }

    public func pause(for duration: Duration) {
        settings.pause(for: duration)
        reportPauseChange()
        restart(runNow: false)
    }

    /// 다시 시작하면 바로 한 번 돈다.
    public func resume() {
        settings.resume()
        reportPauseChange()
        restart(runNow: true)
    }

    public func stop() {
        started = false
        loop?.cancel()
        loop = nil
    }

    private func restart(runNow: Bool) {
        guard started else { return }
        loop?.cancel()
        loop = Task { await self.cycle(runNow: runNow) }
    }

    private func reportPauseChange() {
        let paused = settings.pauseRemaining != nil
        guard paused != pauseShown else { return }
        pauseShown = paused
        onPauseChange()
    }

    /// `runNow`면 일시정지와 상관없이 한 번 돈다(시작, 지금 검사, 재개). 그 뒤로는 쉬는 동안 돌지 않고, 일시정지가 끝나는 때 깨어나
    /// 알리고 돈다. 쉬지 않으면 마지막 검사부터 주기만큼 잔다.
    private func cycle(runNow: Bool) async {
        var runNext = runNow
        while !Task.isCancelled {
            if runNext {
                await run()
                lastRun = clock()
            }
            guard !Task.isCancelled else { return }
            reportPauseChange()
            let pause = settings.pauseRemaining
            let interval = settings.checkedScanInterval()
            let wait = pause ?? lastRun.map { interval - $0.duration(to: clock()) } ?? .zero
            onSchedule(max(wait, .zero))
            do {
                if wait > .zero { try await sleep(wait) }
            } catch {
                return
            }
            if pause != nil {
                // 아직 쉬는 중이면(일시정지를 늘린 경우는 깨워서 다시 들어온다) 다시 잔다.
                guard settings.pauseRemaining == nil else {
                    runNext = false
                    continue
                }
                reportPauseChange()
            }
            runNext = true
        }
    }
}
