import HaetaeAppCore
import HaetaeShared
import SwiftUI

/// 메뉴바 패널(R4, WO-14 3번). 탐지에서 온 글(제목·이유·검사 ID)은 `Text(verbatim:)`로만 그린다 — 마크다운·링크로 해석되지 않게(D12).
struct PanelView: View {
    let state: AppState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            DaemonStatusView(state: state)
            if let scan = state.scan {
                Divider()
                ScanSummaryView(scan: scan)
                ScanWarningsView(scan: scan)
                Divider()
                RiskListView(scan: scan)
            }
            Divider()
            HStack {
                if let scan = state.scan {
                    Button("지금 검사") { scan.scanNow() }
                    if scan.pausedUntil == nil {
                        Button("1시간 일시정지") { scan.pause(for: .seconds(3_600)) }
                    } else {
                        Button("재개") { scan.resume() }
                    }
                }
                Spacer()
                Button("설정") {
                    // Dock 아이콘이 없는 앱이라 앞으로 가져오지 않으면 설정 창이 다른 앱 뒤에 뜬다.
                    NSApp.activate()
                    openSettings()
                }
                Button("종료") { state.quit() }
            }
        }
        .padding()
        .frame(width: 360)
    }
}

private struct DaemonStatusView: View {
    let state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 쉬는 중이면 그것부터 보인다 — 쉬는 동안 연결이 끊기면 상태는 "연결 중"에 머문다.
            if let until = state.scan?.pausedUntil {
                Label("일시정지 중 (\(until.formatted(date: .omitted, time: .shortened))까지)", systemImage: "pause.circle")
            }
            Label(statusText, systemImage: statusSymbol)
                .foregroundStyle(isFailure ? .red : .primary)
            if state.needsInstall {
                Text("`/Applications`에 설치한 뒤 실행하세요. 이 위치에서는 데몬을 등록하지 않습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if state.daemonStatus == .requiresApproval {
                Button("로그인 항목 설정 열기") { state.openLoginItemsSettings() }
            }
        }
    }

    private var statusText: String {
        switch state.daemonStatus {
        case .notRegistered: "데몬이 등록되지 않음"
        case .requiresApproval: "시스템 설정에서 승인이 필요함"
        case .registrationFailed: "등록 실패"
        case .identityError: "앱 서명을 확인하지 못함"
        case .connecting: "연결 중"
        case .connected(let build): "연결됨 (빌드 \(build))"
        case .verificationFailed: "데몬 검증 실패"
        case .relaunchNeeded: "업데이트됨 — Haetae를 다시 실행하세요"
        case .staleDaemon: "등록된 데몬이 옛 빌드"
        case .rolledBack: "데몬이 옛 빌드로 되돌려짐 — 모든 요청 거부"
        case .noResponse: "데몬 응답 없음"
        case .malformedReply: "데몬 응답 형식 오류"
        case .daemonError(let code): "데몬 오류 (코드 \(code))"
        }
    }

    private var statusSymbol: String {
        if case .connected = state.daemonStatus { return "checkmark.shield" }
        return isFailure ? "exclamationmark.shield" : "shield"
    }

    private var isFailure: Bool { state.daemonStatus.isProblem }
}

private struct ScanSummaryView: View {
    let scan: ScanController

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow {
                Text("마지막 검사").foregroundStyle(.secondary)
                Text(scan.lastReport.map { $0.finishedAt.formatted(date: .omitted, time: .shortened) } ?? "아직 없음")
            }
            GridRow {
                Text("다음 검사").foregroundStyle(.secondary)
                Text(scan.nextScanAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—")
            }
            GridRow {
                Text("판정").foregroundStyle(.secondary)
                Text("규칙 판정")
            }
            if let report = scan.lastReport {
                GridRow {
                    Text("패턴 버전").foregroundStyle(.secondary)
                    Text("\(report.patternVersion)")
                }
            }
        }
        .font(.callout)
    }
}

/// 살펴볼 것. 높은 것(못 보낸 건, 알림 꺼짐)은 빨강.
private struct ScanWarningsView: View {
    let scan: ScanController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !scan.notificationsEnabled {
                warning("알림이 꺼져 있어요. 시스템 설정의 알림에서 Haetae를 켜 주세요.", high: true)
            }
            if let dropped = scan.lastReport?.droppedFindings, dropped > 0 {
                warning("\(dropped)건은 표시하지 못했어요. 다음 검사에서 이어서 받아요.", high: true)
            }
            if let gap = scan.lastReport?.scanGap {
                warning(gap < 60 ? "1분 미만 동안 검사하지 못했어요." : "\(Int(gap / 60))분 동안 검사하지 못했어요.", high: false)
            }
            if let failed = scan.lastReport?.failedChecks, !failed.isEmpty {
                // 검사 ID는 데몬이 형식을 검증한 값이지만 보이는 글이라 verbatim으로.
                warningVerbatim("검사 \(failed.count)개 실패: \(failed.joined(separator: ", "))")
            }
            switch scan.problem {
            case .storeFailed: warning("기록을 저장하지 못했어요. 다음 검사에서 다시 저장해요.", high: false)
            case .ackFailed: warning("데몬에 결과를 알리지 못했어요. 다음 검사에서 다시 알려요.", high: false)
            case nil: EmptyView()
            }
            if scan.recordRebuilt {
                warning("Haetae 기록을 읽지 못해 데몬 기록으로 다시 만들었어요.", high: false)
            }
        }
        .font(.callout)
    }

    private func warning(_ text: String, high: Bool) -> some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .foregroundStyle(high ? .red : .orange)
    }

    private func warningVerbatim(_ text: String) -> some View {
        Label { Text(verbatim: text) } icon: { Image(systemName: "exclamationmark.triangle") }
            .foregroundStyle(.orange)
    }
}

private struct RiskListView: View {
    let scan: ScanController

    var body: some View {
        if scan.risks.isEmpty {
            // 한 번도 검사하지 못했으면 "없음"이라고 하지 않는다 — 감시가 돌지 않는데 안심하게 하지 않게.
            Text(scan.lastReport == nil ? "아직 검사하지 않았어요" : "발견된 위험 없음").foregroundStyle(.secondary)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(scan.risks, id: \.fingerprint) { risk in
                        RiskRow(risk: risk, verified: scan.isVerified(risk))
                    }
                }
            }
            .frame(maxHeight: 260)
        }
    }
}

private struct RiskRow: View {
    let risk: Risk
    let verified: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(levelText)
                    .font(.caption.bold())
                    .foregroundStyle(levelColor)
                Text(verbatim: risk.finding.title)
                    .lineLimit(2)
                if !verified {
                    Text("확인 전").font(.caption).foregroundStyle(.secondary)
                }
                if !risk.isRisk {
                    Text("위험 아님").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(verbatim: risk.reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .accessibilityElement(children: .combine)
    }

    private var levelText: String {
        switch risk.level {
        case .high: "높음"
        case .medium: "중간"
        case .low: "낮음"
        }
    }

    private var levelColor: Color {
        switch risk.level {
        case .high: .red
        case .medium: .orange
        case .low: .secondary
        }
    }
}
