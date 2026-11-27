import Foundation
import os
import UserNotifications

/// 사용자 알림(D12). 본문은 고정 문구만 쓴다 — 탐지 내용·판정 이유는 공격자가 고를 수 있는 글이라 넣지 않는다(T8).
/// 잠금 화면에서는 본문을 가린다(`hiddenPreviewsBodyPlaceholder`, T19).
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private static let category = "haetae.risk"
    private static let deadline: Duration = .seconds(5)
    private let center = UNUserNotificationCenter.current()

    /// 앱이 뜰 때 한 번. 권한을 묻고(이미 정했으면 묻지 않는다) 카테고리를 건다.
    func setUp() async {
        center.delegate = self
        center.setNotificationCategories([UNNotificationCategory(
            identifier: Self.category, actions: [], intentIdentifiers: [], hiddenPreviewsBodyPlaceholder: "Haetae 알림", options: []
        )])
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            Log.app.error("알림 권한 요청 실패 (\((error as NSError).code))")
        }
    }

    /// 검사마다 본다(D28) — 꺼져 있으면 메뉴바 아이콘으로 경고한다. 스타일이 "없음"이면 화면에 아무것도 뜨지 않아 꺼진 것으로 본다.
    /// 알림 서버가 5초 안에 답하지 않아도 꺼진 것으로 본다 — 멈춘 서버에 옛 값(켜짐)으로 남지 않게.
    func isEnabled() async -> Bool {
        let center = center
        return await withDeadline {
            let settings = await center.notificationSettings()
            return settings.authorizationStatus == .authorized && settings.alertSetting == .enabled && settings.alertStyle != .none
        }
    }

    /// - Returns: 등록했으면 true.
    func notifyRisks(count: Int) async -> Bool {
        await post("보안 위험 \(count)건이 발견됐어요. 메뉴바에서 확인하세요.")
    }

    /// 기록 파일을 읽지 못했거나 데몬 요약으로 다시 만들었다(Q72). 지우려 한 흔적일 수 있지만, 업데이트로 형식이 바뀌어도 뜰 수 있어
    /// 탓하지 않는 문구로 쓴다.
    func notifyRecordRebuilt() async -> Bool {
        await post("Haetae 기록을 읽지 못해 다시 만들었어요. 메뉴바에서 확인하세요.")
    }

    /// 패널이 열려 앱이 앞에 있어도 배너를 띄운다.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// 등록을 마친 뒤 돌아온다 — 파이프라인은 그다음에 ack한다(D24). 알림 서버가 응답하지 않으면 5초 뒤 false — 기다리다 검사가
    /// 멈추지 않게(같은 사용자 권한으로 알림 서버를 멈출 수 있다고 본다, WO-14 1단계 재리뷰).
    private func post(_ body: String) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = "Haetae"
        content.body = body
        content.categoryIdentifier = Self.category
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        let center = center
        return await withDeadline {
            do {
                try await center.add(request)
                return true
            } catch {
                Log.app.error("알림 보내기 실패 (\((error as NSError).code))")
                return false
            }
        }
    }

    /// 알림 서버(usernoted)가 멈춰도 기다리는 쪽이 멈추지 않게 `deadline`이 지나면 false. 일은 따로 돌려 두고 먼저 온 쪽만 받는다.
    private func withDeadline(_ work: @escaping @MainActor () async -> Bool) async -> Bool {
        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
                let once = Once(continuation)
                Task { once.resume(with: .success(await work())) }
                Task {
                    do { try await Task.sleep(for: Self.deadline) } catch { return }
                    Log.app.error("알림 서버 응답 없음")
                    once.resume(with: .success(false))
                }
            }
        } catch {
            return false
        }
    }
}
