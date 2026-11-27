import Foundation
import HaetaeShared

/// 한 번의 검사 결과(상태 콜백). 표시와 아이콘은 WO-14의 `AppState`가 정한다.
public struct ScanReport: Sendable, Equatable {
    public var finishedAt: Date
    public var daemonBuild: Int
    public var patternVersion: Int
    public var failedChecks: [String]
    /// 검사 공백(Q31). 앱이 받았다고 알릴(ack) 때까지 매 응답에 실린다(Q67).
    public var scanGap: TimeInterval?
    /// 응답 한도 때문에 이번에 보내지 못한 건수.
    public var droppedFindings: Int
    /// 이번에 알린 새 위험 수.
    public var alerted: Int
    /// 기록이 지워지거나 바뀌어 데몬 요약으로 다시 만든 수(Q69·Q71).
    public var restored: Int
}

/// 파이프라인이 멈춘 곳. 원인 오류는 바꾸지 않고 그대로 싣는다 — `AppState`가 한 함수에서 상태로 바꾼다(WO-14 0번).
public enum ScanFailure: Error {
    case collect(any Error)
    /// 기록을 쓰지 못해 ack하지 않았다(D24). 알림은 이미 갔다.
    case store(any Error)
    case ack(any Error)
}

/// 수집 → 해결 반영 → 기록 맞추기 → 판정 → 저장 → 알림 → 쓰기 → ack(WO-13 3번, 순서를 바꾸지 않는다).
@MainActor
public final class ScanPipeline {
    private let source: any FindingSource
    private let store: RiskStore
    private let judgeProvider: () -> any RiskJudge
    private let notify: (_ count: Int, _ highest: RiskLevel) -> Void
    private let report: (Result<ScanReport, ScanFailure>) -> Void
    private let now: () -> Date
    /// 이 실행에서 알렸지만 아직 ack가 성공하지 않은 지문과 그 판정. 새 건인지는 이것으로만 정한다 — 파일 기록은 같은 사용자가 지문을
    /// 심어 알림 없이 ack하게 만들 수 있다(1단계 보안 H1). ack가 성공하면 지운다 — 남기면 해결 뒤 다시 나타난 위험을 알리지 않는다.
    /// ack 응답만 잃은 경우도 데몬 응답으로 지운다(`forgetDelivered`).
    private var awaitingAck: [String: Risk] = [:]
    private var running: Task<Void, Never>?

    public init(
        source: any FindingSource, store: RiskStore, judgeProvider: @escaping () -> any RiskJudge,
        notify: @escaping (_ count: Int, _ highest: RiskLevel) -> Void,
        report: @escaping (Result<ScanReport, ScanFailure>) -> Void, now: @escaping () -> Date = { Date() }
    ) {
        self.source = source
        self.store = store
        self.judgeProvider = judgeProvider
        self.notify = notify
        self.report = report
        self.now = now
    }

    /// 겹쳐 돌지 않는다 — 돌고 있으면 그 결과를 기다린다(XPC 응답은 Task 취소를 무시하므로 취소로 끊지 않는다).
    public func run() async {
        if let running { return await running.value }
        let task = Task { await scan() }
        running = task
        await task.value
        running = nil
    }

    private func scan() async {
        let result: CollectResult
        do {
            result = try await source.collect()
        } catch {
            return report(.failure(.collect(error)))
        }
        store.markResolved(result.resolved)
        let current = Set(result.findings.map(\.fingerprint))
        forgetDelivered(result, current: current)
        let restored = result.notified.map {
            store.reconcile(notified: $0, current: current, failedChecks: Set(result.failedChecks), complete: (result.droppedFindings ?? 0) == 0).restored
        } ?? 0

        let fresh = result.findings.filter { awaitingAck[$0.fingerprint] == nil }
        var alerts: [Risk] = []
        if !fresh.isEmpty {
            let judged = Self.verified(await judgeProvider().judge(fresh), for: fresh, at: now())
            for risk in judged { awaitingAck[risk.fingerprint] = risk }
            alerts = judged.filter(\.isRisk)
        }
        // 이미 알린 것도 응답의 원본으로 다시 저장한다 — 데몬과 같은 증거여야 다시 뜬 뒤 해시가 맞는다(Q71).
        let stored = store.save(result.findings.compactMap { finding in
            awaitingAck[finding.fingerprint].map { risk in
                var risk = risk
                risk.finding = finding
                return risk
            }
        })
        if let highest = alerts.map(\.level).max(by: { $0.rank < $1.rank }) { notify(alerts.count, highest) }
        store.purge()
        do {
            try store.commit()
        } catch {
            return report(.failure(.store(error)))
        }

        let fingerprints = Array(stored)
        do {
            // 0건이어도 보낸다 — 데몬은 ack로만 검사 공백 표시를 지운다(Q67).
            for start in stride(from: 0, through: max(fingerprints.count - 1, 0), by: HaetaeLimits.maxAckFingerprints) {
                let chunk = Array(fingerprints[start ..< min(start + HaetaeLimits.maxAckFingerprints, fingerprints.count)])
                try await source.ack(chunk)
                for fingerprint in chunk { awaitingAck[fingerprint] = nil }
            }
        } catch {
            return report(.failure(.ack(error)))
        }
        report(.success(ScanReport(
            finishedAt: now(), daemonBuild: result.daemonBuild, patternVersion: result.patternVersion, failedChecks: result.failedChecks,
            scanGap: result.scanGap, droppedFindings: result.droppedFindings ?? 0, alerted: alerts.count, restored: restored
        )))
    }

    /// 데몬이 이미 받은(ack를 반영한) 지문을 잊는다 — ack 응답만 잃으면(타임아웃, 데몬이 꺼지는 순간) 그 지문이 남아, 해결 뒤 다시
    /// 나타났을 때 알리지 않고 ack했다(2단계 리뷰 실측). 데몬은 pending을 매 응답 다시 보내므로, 알림 완료 요약이나 해결 목록에 있거나,
    /// 응답이 잘리지 않았는데 이번 탐지에 없는 지문은 더는 pending이 아니다.
    private func forgetDelivered(_ result: CollectResult, current: Set<String>) {
        for fingerprint in result.resolved { awaitingAck[fingerprint] = nil }
        for summary in result.notified ?? [] { awaitingAck[summary.fingerprint] = nil }
        if (result.droppedFindings ?? 0) == 0 { awaitingAck = awaitingAck.filter { current.contains($0.key) } }
    }

    /// 판정 결과를 믿지 않고 맞춘다(D10·D24, WO-22 4번): 지문으로 맞추고, 빠지거나 겹친 건과 LLM 판정이 아닌 건은 규칙 판정으로,
    /// `finding`은 원본으로, 규칙 높음은 높음·위험 그대로(LLM은 중간→낮음까지만 낮춘다. 올리는 것은 제한 없음), 이유는 상한으로 자른다
    /// (넘치면 저장되지 않아 영영 ack되지 않는다). WO-22의 `VerdictPolicy`는 이 함수 안에서 부른다 — D10을 한 곳에만 둔다.
    static func verified(_ judged: [Risk], for findings: [Finding], at: Date) -> [Risk] {
        var byFingerprint: [String: Risk] = [:]
        for risk in judged where byFingerprint[risk.fingerprint] == nil { byFingerprint[risk.fingerprint] = risk }
        return findings.map { finding in
            guard var risk = byFingerprint[finding.fingerprint], risk.judgedBy == .llm else { return RuleOnlyJudge.risk(for: finding, at: at) }
            risk.finding = finding
            if finding.ruleLevel == .high { risk.level = .high }
            // 높음은 늘 위험이다(LLM이 올리면서 위험 아님이라고 해도 — "높음인데 위험 아님"으로 보이지 않게).
            risk.isRisk = risk.level == .high || (risk.isRisk && risk.level != .low)
            risk.reason = String(String.UnicodeScalarView(risk.reason.unicodeScalars.prefix(Risk.maxReasonChars)))
            risk.resolvedAt = nil
            return risk
        }
    }
}
