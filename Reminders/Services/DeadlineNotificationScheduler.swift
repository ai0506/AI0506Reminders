import Foundation
import UserNotifications

@MainActor
final class DeadlineNotificationScheduler {
    static let shared = DeadlineNotificationScheduler()
    private let center = UNUserNotificationCenter.current()
    private let identifierPrefix = "deadline-reminder-"

    private init() {}

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .badge, .sound])
        } catch {
            return false
        }
    }

    func scheduleIfPermitted(for deadlines: [Deadline]) {
        Task {
            guard UserDefaults.standard.bool(forKey: "deadline-alerts-enabled") else { return }
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            await reschedule(deadlines)
        }
    }

    func reschedule(_ deadlines: [Deadline]) async {
        // 必须按前缀清掉**所有**已排的截止提醒，不能只清当前数组里这些 id：
        // 服务端删掉的、或这次同步窗口之外的 Deadline 已经不在数组里了，
        // 它们的通知会留下来继续弹——用户看到一条早就不存在的提醒。
        await removePendingDeadlineAlerts()
        let calendar = Calendar.current
        let candidates = deadlines
            .filter { !$0.isCompleted && $0.dueDate > .now }
            .sorted { $0.dueDate < $1.dueDate }
            .prefix(48)

        for deadline in candidates {
            let triggerDate: Date
            if deadline.allDay {
                triggerDate = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: deadline.dueDate) ?? deadline.dueDate
            } else {
                triggerDate = calendar.date(byAdding: .minute, value: -15, to: deadline.dueDate) ?? deadline.dueDate
            }
            guard triggerDate > .now else { continue }

            let content = UNMutableNotificationContent()
            content.title = deadline.title
            content.body = deadline.allDay ? "今天截止" : "将在 15 分钟后截止"
            content.sound = .default
            content.threadIdentifier = "deadlines"
            content.userInfo = ["deadlineID": deadline.id]
            let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: triggerDate)
            let request = UNNotificationRequest(
                identifier: identifierPrefix + deadline.id,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            try? await center.add(request)
        }
    }

    func removeAllDeadlineAlerts() {
        Task { await removePendingDeadlineAlerts() }
    }

    /// 只动本 App 排的截止提醒（按 `identifierPrefix` 筛），
    /// 不用 `removeAllPendingNotificationRequests()` 一把梭。
    private func removePendingDeadlineAlerts() async {
        let pending = await center.pendingNotificationRequests()
        let ours = pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        guard !ours.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: ours)
    }
}
