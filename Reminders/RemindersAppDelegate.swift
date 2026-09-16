import UIKit
import UserNotifications

final class RemindersAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let deadlineID = response.notification.request.content.userInfo["deadlineID"] as? String {
            Task { @MainActor in
                NotificationCenter.default.post(name: .openDeadlineRoute, object: deadlineID)
            }
        }
        completionHandler()
    }
}
