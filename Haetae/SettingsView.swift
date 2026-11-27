import AppKit
import HaetaeAppCore
import SwiftUI

/// 설정 창(WO-55, Q81 2번): 일반·알림·정보 탭. 새 기능은 없고 지금 있는 것을 모은다. WO-23 모델 설정은 탭을 하나 더해 넣는다.
struct SettingsView: View {
    let state: AppState

    var body: some View {
        TabView {
            Tab("일반", systemImage: "gearshape") {
                GeneralSettings(state: state)
            }
            Tab("알림", systemImage: "bell") {
                // 앱 서명 오류로 검사 쪽이 없으면 알 수 없다 — "켜져 있어요"로 보이지 않게(보안 리뷰 의견).
                NotificationSettings(enabled: state.scan?.notificationsEnabled)
            }
            Tab("정보", systemImage: "info.circle") {
                AboutSettings(state: state)
            }
        }
        .frame(width: 460)
        // 설정 창이 열릴 때 알림 상태를 다시 읽는다(설계 리뷰 L3).
        .task { await state.scan?.refreshNotifications() }
    }
}

private struct GeneralSettings: View {
    let state: AppState

    /// 5~60분(`AppSettings.intervalRange`) 안에서 고른다.
    private static let intervalMinutes = [5, 10, 15, 30, 60]

    var body: some View {
        Form {
            if let scan = state.scan {
                Section("검사") {
                    // 바꾸면 스케줄러가 바로 다음 검사 시각을 다시 정한다(WO-13 4번).
                    Picker("검사 주기", selection: Binding(
                        get: { Int(scan.scanInterval.components.seconds / 60) },
                        set: { scan.setScanInterval(.seconds($0 * 60)) }
                    )) {
                        // 밖에서 목록에 없는 값(범위 안)을 넣어 두었으면 그 값도 보인다 — 빈칸으로 보이지 않게.
                        let current = Int(scan.scanInterval.components.seconds / 60)
                        ForEach(Set(Self.intervalMinutes + [current]).sorted(), id: \.self) { Text("\($0)분").tag($0) }
                    }
                    LabeledContent("다음 검사") {
                        if let until = scan.pausedUntil {
                            Text("\(PanelTime.clock(until))까지 쉬어요")
                        } else {
                            Text(scan.nextScanAt.map(PanelTime.clock) ?? "—")
                        }
                    }
                }
            }
            Section {
                Toggle("로그인 시 실행", isOn: Binding(
                    get: { state.launchAtLogin },
                    set: { state.setLaunchAtLogin($0) }
                ))
                .disabled(state.needsInstall)
                // 강조색은 토글에만 — 메뉴 글자까지 보라색이 되면 어색하다(2026-11-27 사용자 화면 확인).
                .tint(Brand.primary)
                if state.agentNeedsApproval {
                    LabeledContent("시스템 설정의 로그인 항목에서 Haetae가 꺼져 있어요") {
                        Button("열기") { state.openLoginItemsSettings() }
                    }
                }
                if state.launchAtLoginFailed {
                    Text("로그인 시 실행을 바꾸지 못했어요").foregroundStyle(StatusColor.dangerText)
                }
            } header: {
                Text("시작")
            } footer: {
                Text("끄면 Haetae를 종료할 때 적용돼요.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct NotificationSettings: View {
    let enabled: Bool?

    var body: some View {
        Form {
            Section {
                LabeledContent("알림") {
                    switch enabled {
                    case true?: Label("켜져 있어요", systemImage: "bell.fill")
                    case false?: Label("꺼져 있어요", systemImage: "bell.slash").foregroundStyle(StatusColor.warningText)
                    case nil: Text("알 수 없어요").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("시스템 설정") {
                    Button("알림 설정 열기") { Notifier.openSystemSettings() }
                }
            } footer: {
                // D12·T19: 알림에는 고정 문구만 — 무엇을 찾았는지는 패널에서만 보인다.
                Text("위험을 찾으면 \"보안 위험 N건\"처럼 고정된 문구로만 알려요. 무엇을 찾았는지는 메뉴바 패널에서만 보여요. 잠금 화면에서 본문을 보일지는 시스템의 미리보기 설정을 따라요.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettings: View {
    let state: AppState

    var body: some View {
        Form {
            Section {
                LabeledContent("버전", value: Self.version)
                LabeledContent("데몬", value: state.daemonStatus.detail)
                LabeledContent("판정", value: state.scan?.judgeName ?? "—")
                LabeledContent("패턴 버전", value: state.scan?.lastReport.map { "\($0.patternVersion)" } ?? "—")
                LabeledContent("마지막 검사", value: state.scan?.lastReport.map { PanelTime.dateTime($0.finishedAt) } ?? "아직 없어요")
            }
        }
        .formStyle(.grouped)
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}
