import Foundation
import UserNotifications

enum NotificationService {
    static func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    static func notifyDownloadFinished(title: String, itemID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = "已加入片库"
        content.body = title
        content.sound = .default
        content.userInfo = ["itemID": itemID.uuidString]

        let request = UNNotificationRequest(
            identifier: "download-\(itemID.uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
