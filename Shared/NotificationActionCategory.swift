import Foundation
import MarmotKit

/// Category and action identifiers for actionable message notifications.
/// Shared so both the main app's local presentations and the NSE's decorated
/// content stamp the same category; only the main app registers the actions.
nonisolated enum NotificationActionCategory {
    static let message = "dm_message_actions"
    static let replyActionIdentifier = "dm_action_reply"
    static let markReadActionIdentifier = "dm_action_mark_read"

    /// Both actions need a concrete message target — reply publishes into the
    /// notified conversation and mark-read advances the read marker past the
    /// notified message — so invites and summary presentations stay
    /// action-free.
    static func identifier(trigger: NotificationTriggerFfi, messageIdHex: String?) -> String? {
        switch trigger {
        case .newMessage:
            guard let messageIdHex, !messageIdHex.isEmpty else { return nil }
            return message
        case .groupInvite:
            return nil
        }
    }
}
