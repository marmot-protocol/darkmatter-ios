import Foundation
import UserNotifications

enum NotificationContentDecorator {
    static func apply(
        _ presentation: LocalNotificationPresentation,
        to content: UNMutableNotificationContent,
        applicationBadgeCount: Int? = nil
    ) {
        content.title = presentation.title
        content.body = presentation.body
        content.sound = .default
        content.threadIdentifier = presentation.threadIdentifier
        content.targetContentIdentifier = presentation.identifier
        if let applicationBadgeCount {
            applyApplicationBadgeCount(applicationBadgeCount, to: content)
        }
        if let categoryIdentifier = presentation.categoryIdentifier {
            content.categoryIdentifier = categoryIdentifier
        }
        var userInfo = content.userInfo
        for (key, value) in presentation.userInfo {
            userInfo[key] = value
        }
        content.userInfo = userInfo
    }

    static func makeContent(
        for presentation: LocalNotificationPresentation,
        applicationBadgeCount: Int? = nil
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        apply(
            presentation,
            to: content,
            applicationBadgeCount: applicationBadgeCount
        )
        return content
    }

    static func applyApplicationBadgeCount(
        _ count: Int,
        to content: UNMutableNotificationContent
    ) {
        content.badge = NSNumber(value: max(count, 0))
    }
}
