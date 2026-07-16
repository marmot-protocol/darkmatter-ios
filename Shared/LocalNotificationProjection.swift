import Foundation
import MarmotKit

struct LocalNotificationRoute: Equatable, Hashable {
    let accountRef: String
    let groupIdHex: String
    let notificationKey: String
    let messageIdHex: String?
}

struct LocalNotificationPresentation: Equatable {
    let identifier: String
    let threadIdentifier: String
    let title: String
    let body: String
    let route: LocalNotificationRoute
    let timestamp: Date
    let userInfo: [String: String]
    // Defaulted so display-only presentations (summaries, failure fallbacks)
    // stay action-free without touching every construction site.
    var categoryIdentifier: String? = nil
    // Communication-notification decoration inputs; defaulted so summaries and
    // fallbacks stay undecorated. The picture URL is pre-sanitized.
    var senderName: String? = nil
    var senderPictureUrl: String? = nil
    var isGroupConversation: Bool = false
}

nonisolated enum LocalNotificationProjection {
    static let accountRefKey = "dm_account_ref"
    static let groupIdHexKey = "dm_group_id_hex"
    static let notificationKeyKey = "dm_notification_key"
    static let messageIdHexKey = "dm_message_id_hex"

    private static let maxPreviewLength = 240

    /// `nickname` resolves the viewer's private label for a (owner, contact)
    /// pair — the same App-Group-backed override the in-app UI reads — so a set
    /// nickname wins over the kind:0 sender name in notification titles too.
    /// Defaults to none so the many test/summary call sites stay unchanged.
    static func makePresentation(
        for update: NotificationUpdateFfi,
        nickname: (String, String) -> String? = { _, _ in nil }
    ) -> LocalNotificationPresentation? {
        guard !update.isFromSelf else { return nil }

        let route = LocalNotificationRoute(
            accountRef: update.accountRef,
            groupIdHex: update.groupIdHex,
            notificationKey: notificationIdentifier(for: update),
            messageIdHex: update.messageIdHex
        )

        let senderName = displayName(
            for: update.sender,
            nickname: nickname(update.accountIdHex, update.sender.accountIdHex)
        )
        let preview = sanitizedPreview(update.previewText)
        let content = contentText(
            trigger: update.trigger,
            isDm: update.isDm,
            isMention: update.isMention,
            senderName: senderName,
            groupName: ContentSanitizer.groupName(update.groupName),
            preview: preview
        )

        return LocalNotificationPresentation(
            identifier: route.notificationKey,
            threadIdentifier: threadIdentifier(for: update),
            title: content.title,
            body: content.body,
            route: route,
            timestamp: Date(timeIntervalSince1970: TimeInterval(update.timestampMs) / 1000),
            userInfo: userInfo(for: route),
            categoryIdentifier: NotificationActionCategory.identifier(
                trigger: update.trigger,
                messageIdHex: update.messageIdHex
            ),
            senderName: senderName,
            senderPictureUrl: ContentSanitizer.imageURL(update.sender.pictureUrl)?.absoluteString,
            isGroupConversation: !update.isDm
        )
    }

    static func route(from userInfo: [AnyHashable: Any]) -> LocalNotificationRoute? {
        guard let accountRef = stringValue(userInfo[accountRefKey]), !accountRef.isEmpty,
              let groupIdHex = stringValue(userInfo[groupIdHexKey]), !groupIdHex.isEmpty,
              let notificationKey = stringValue(userInfo[notificationKeyKey]), !notificationKey.isEmpty
        else { return nil }

        return LocalNotificationRoute(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            notificationKey: notificationKey,
            messageIdHex: stringValue(userInfo[messageIdHexKey])
        )
    }

    static func userInfo(for route: LocalNotificationRoute) -> [String: String] {
        var userInfo = [
            accountRefKey: route.accountRef,
            groupIdHexKey: route.groupIdHex,
            notificationKeyKey: route.notificationKey
        ]
        if let messageIdHex = route.messageIdHex {
            userInfo[messageIdHexKey] = messageIdHex
        }
        return userInfo
    }

    private static func contentText(
        trigger: NotificationTriggerFfi,
        isDm: Bool,
        isMention: Bool,
        senderName: String,
        groupName: String?,
        preview: String?
    ) -> (title: String, body: String) {
        switch trigger {
        case .groupInvite:
            return (
                title: L10n.string("Group invite"),
                body: groupName.map { L10n.formatted("Invitation to %@", $0) }
                    ?? L10n.string("Open White Noise to view the invite")
            )
        case .newMessage:
            if isDm {
                return (title: senderName, body: preview ?? L10n.string("New encrypted message"))
            }
            if isMention {
                return (
                    title: groupName ?? L10n.string("Group message"),
                    body: preview.map { L10n.formatted("%@ mentioned you: %@", senderName, $0) }
                        ?? L10n.formatted("%@ mentioned you", senderName)
                )
            }
            return (
                title: groupName ?? L10n.string("Group message"),
                body: preview.map { L10n.formatted("%@: %@", senderName, $0) }
                    ?? L10n.formatted("%@ sent a message", senderName)
            )
        }
    }

    private static func displayName(for user: NotificationUserFfi, nickname: String?) -> String {
        // A private nickname overrides the kind:0 sender name; it is already
        // sanitized at the store boundary but re-checked here for safety.
        if let nickname = ContentSanitizer.displayName(nickname) {
            return nickname
        }
        if let name = ContentSanitizer.displayName(user.displayName) {
            return name
        }
        if user.accountIdHex.isEmpty {
            return L10n.string("Someone")
        }
        return IdentityFormatter.short(user.accountIdHex)
    }

    private static func sanitizedPreview(_ raw: String?) -> String? {
        ContentSanitizer.singleLine(raw, maxLength: maxPreviewLength)
    }

    private static func notificationIdentifier(for update: NotificationUpdateFfi) -> String {
        if !update.notificationKey.isEmpty {
            return update.notificationKey
        }
        if let messageIdHex = update.messageIdHex, !messageIdHex.isEmpty {
            return "\(update.accountRef):\(update.groupIdHex):\(messageIdHex)"
        }
        return "\(update.accountRef):\(update.groupIdHex):\(update.timestampMs)"
    }

    private static func threadIdentifier(for update: NotificationUpdateFfi) -> String {
        if !update.conversationKey.isEmpty {
            return update.conversationKey
        }
        return "\(update.accountRef):\(update.groupIdHex)"
    }

    private static func stringValue(_ value: Any?) -> String? {
        value as? String
    }
}
