import Foundation

/// 사용자 설정. 검사 주기는 `UserDefaults`에 두는데, 같은 사용자 권한으로 `defaults write` 할 수 있어 읽을 때마다 범위를 보고(D28)
/// 이 실행이 아는 값보다 늘어 있으면 `onWeakened`로 알린다. 일시정지는 메모리에만 둔다 — 밖에서 쓴 값으로 감시를 멈추지 못하게
/// (하루마다 "지금 + 23시간"을 다시 쓰면 끝없이 멈췄다, 1단계 보안 리뷰 실측). 앱이 다시 뜨면 풀린다.
/// 주기와 일시정지의 주인은 이것 하나다. 바꾸는 쪽(UI)은 `ScanScheduler`를 거친다 — 스케줄러가 여기에 쓰고 스스로 깨어난다.
@MainActor
public final class AppSettings {
    public enum Weakening: Sendable, Equatable {
        case intervalIncreased(from: Duration, to: Duration)
        case paused(until: Date)
    }

    public static let defaultInterval: Duration = .seconds(900)
    public static let intervalRange: ClosedRange<Duration> = .seconds(300) ... .seconds(3_600)
    /// 일시정지의 상한. 지나면 저절로 다시 검사한다.
    public static let maxPause: Duration = .seconds(24 * 60 * 60)

    private static let intervalKey = "scanIntervalSeconds"

    private let defaults: UserDefaults
    private let now: () -> Date
    private let clock: () -> ContinuousClock.Instant
    /// 이 실행이 마지막으로 본(또는 쓴) 주기.
    private var knownInterval: Duration
    /// 벽시계가 아니라 흐르는 시간으로 잰다 — 시계를 뒤로 돌려 일시정지를 늘리지 못하게.
    private var pauseEnd: ContinuousClock.Instant?
    public var onWeakened: ((Weakening) -> Void)?

    /// - Parameters:
    ///   - defaults: 테스트에서는 `UserDefaults(suiteName:)`을 넣는다.
    ///   - now, clock: 표시용 시각과 일시정지를 재는 시계. 테스트에서 주입한다.
    public init(defaults: UserDefaults = .standard, now: @escaping () -> Date = { Date() }, clock: @escaping () -> ContinuousClock.Instant = { .now }) {
        self.defaults = defaults
        self.now = now
        self.clock = clock
        knownInterval = Self.validInterval(defaults.integer(forKey: Self.intervalKey))
    }

    /// 검사 주기(보기용 — 알리지 않는다). 저장된 값이 범위(5~60분)를 벗어나면 기본값(15분)이다.
    public var scanInterval: Duration {
        Self.validInterval(defaults.integer(forKey: Self.intervalKey))
    }

    /// 스케줄러가 잠들기 전에 부른다. 바꾸는 함수와 함께 `package` — 앱(UI)은 `ScanScheduler`를 거쳐야 스케줄러가 깨어난다. 밖에서 늘려 놓았으면 알린다 — 범위 안이면 데몬의 "정지 의심"(120분)에도 걸리지 않는다.
    /// 앱이 뜨기 전에 바꾼 것은 알 수 없다(WO-40에서 시작할 때의 주기를 기록한다).
    package func checkedScanInterval() -> Duration {
        let current = scanInterval
        if current > knownInterval { onWeakened?(.intervalIncreased(from: knownInterval, to: current)) }
        knownInterval = current
        return current
    }

    /// 범위를 벗어나면 바꾸지 않고 false.
    @discardableResult
    package func setScanInterval(_ interval: Duration) -> Bool {
        guard Self.intervalRange.contains(interval) else { return false }
        let old = checkedScanInterval()
        defaults.set(Int(interval.components.seconds), forKey: Self.intervalKey)
        knownInterval = interval
        if interval > old { onWeakened?(.intervalIncreased(from: old, to: interval)) }
        return true
    }

    /// 일시정지가 끝나기까지 남은 시간. 쉬지 않으면 nil.
    public var pauseRemaining: Duration? {
        guard let pauseEnd else { return nil }
        let left = clock().duration(to: pauseEnd)
        return left > .zero ? left : nil
    }

    /// 일시정지가 끝나는 시각(표시용). 쉬지 않으면 nil.
    public var pausedUntil: Date? {
        pauseRemaining.map { now().addingTimeInterval($0 / .seconds(1)) }
    }

    /// `duration`만큼 쉰다(상한 24시간). 끝나는 때가 늦춰질 때만 약화로 알린다 — 줄이는 것은 강화다.
    package func pause(for duration: Duration) {
        guard duration > .zero else { return }
        let length = min(duration, Self.maxPause)
        let previous = pauseRemaining
        pauseEnd = clock().advanced(by: length)
        if previous.map({ length > $0 }) ?? true { onWeakened?(.paused(until: now().addingTimeInterval(length / .seconds(1)))) }
    }

    package func resume() {
        pauseEnd = nil
    }

    private static func validInterval(_ seconds: Int) -> Duration {
        let interval = Duration.seconds(seconds)
        return intervalRange.contains(interval) ? interval : defaultInterval
    }
}
