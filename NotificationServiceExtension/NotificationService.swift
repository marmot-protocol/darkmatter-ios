import Foundation
import MarmotKit
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var collectionTask: Task<Void, Never>?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        collectionTask = Task {
            await collectAndDecorateNotification()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        collectionTask?.cancel()
        finish()
    }

    private func collectAndDecorateNotification() async {
        guard let content = bestAttemptContent else {
            finish()
            return
        }

        do {
            let marmot = try Marmot(
                rootPath: AppContainerConfig.productionMarmotRoot().path,
                relayUrls: AppContainerConfig.seedRelays
            )
            try await marmot.start()
            let result = try await marmot.collectNotificationsAfterWake(
                maxWaitMs: 25_000,
                source: .apnsNse
            )

            if let update = result.notifications
                .filter({ !$0.isFromSelf })
                .max(by: { $0.timestampMs < $1.timestampMs }) {
                decorate(content, with: update)
            }
        } catch {
            // Keep the provider payload generic when collection fails. The main
            // app will catch up when it next starts or receives a local event.
        }

        finish()
    }

    private func decorate(_ content: UNMutableNotificationContent, with update: NotificationUpdateFfi) {
        let senderName = displayName(for: update.sender)
        let groupName = singleLine(update.groupName, maxLength: 100)
        let preview = singleLine(update.previewText, maxLength: 240)

        switch update.trigger {
        case .groupInvite:
            content.title = "Group invite"
            content.body = groupName.map { "Invitation to \($0)" } ?? "Open Dark Matter to view the invite"
        case .newMessage:
            if update.isDm {
                content.title = senderName
                content.body = preview ?? "New encrypted message"
            } else {
                content.title = groupName ?? "Group message"
                content.body = preview.map { "\(senderName): \($0)" } ?? "\(senderName) sent a message"
            }
        }

        content.threadIdentifier = update.conversationKey.isEmpty
            ? "\(update.accountRef):\(update.groupIdHex)"
            : update.conversationKey

        content.userInfo = routeUserInfo(for: update)
    }

    private func routeUserInfo(for update: NotificationUpdateFfi) -> [String: String] {
        var userInfo = [
            "dm_account_ref": update.accountRef,
            "dm_group_id_hex": update.groupIdHex,
            "dm_notification_key": update.notificationKey.isEmpty
                ? fallbackNotificationKey(for: update)
                : update.notificationKey
        ]
        if let messageIdHex = update.messageIdHex {
            userInfo["dm_message_id_hex"] = messageIdHex
        }
        return userInfo
    }

    private func fallbackNotificationKey(for update: NotificationUpdateFfi) -> String {
        if let messageIdHex = update.messageIdHex, !messageIdHex.isEmpty {
            return "\(update.accountRef):\(update.groupIdHex):\(messageIdHex)"
        }
        return "\(update.accountRef):\(update.groupIdHex):\(update.timestampMs)"
    }

    private func displayName(for user: NotificationUserFfi) -> String {
        if let name = singleLine(user.displayName, maxLength: 80) {
            return name
        }
        guard user.accountIdHex.count > 17 else {
            return user.accountIdHex.isEmpty ? "Someone" : user.accountIdHex
        }
        return "\(user.accountIdHex.prefix(8))...\(user.accountIdHex.suffix(6))"
    }

    private func singleLine(_ raw: String?, maxLength: Int) -> String? {
        guard let raw else { return nil }
        let collapsed = stripUnsafe(raw)
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(maxLength))
    }

    private func stripUnsafe(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { scalar in
            if scalar == "\n" || scalar == "\t" || scalar == "\r" { return true }
            if scalar.properties.generalCategory == .control { return false }
            switch scalar.value {
            case 0x200E, 0x200F,
                 0x202A...0x202E,
                 0x2066...0x2069,
                 0x061C,
                 0x200B, 0xFEFF:
                return false
            default:
                return true
            }
        }))
    }

    private func finish() {
        guard let contentHandler, let bestAttemptContent else { return }
        self.contentHandler = nil
        contentHandler(bestAttemptContent)
    }
}
