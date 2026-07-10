import Foundation
import MarmotKit

nonisolated enum MessageForwardingPolicy {
    /// Forwarding intentionally copies only the original plaintext. It carries
    /// no sender attribution, quote relation, attachment, or forwarded marker.
    static func forwardableText(for record: AppMessageRecordFfi) -> String? {
        switch MessageSemantics.classify(record) {
        case .chat, .reply, .media:
            return record.plaintext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : record.plaintext
        case .streamFinal, .reaction, .delete, .edit, .agentStreamStart,
             .agentActivity, .agentOperation, .groupSystem, .unknown:
            return nil
        }
    }
}

nonisolated enum MessageEditingPolicy {
    static func canEdit(
        _ record: AppMessageRecordFfi,
        isDeleted: Bool,
        canSendMessages: Bool
    ) -> Bool {
        guard canSendMessages,
              !isDeleted,
              !record.messageIdHex.isEmpty,
              record.direction == "sent"
        else { return false }

        switch MessageSemantics.classify(record) {
        case .chat, .reply, .media:
            return true
        case .streamFinal, .reaction, .delete, .edit, .agentStreamStart,
             .agentActivity, .agentOperation, .groupSystem, .unknown:
            return false
        }
    }

    static func normalizedContent(_ content: String) -> String? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(ContentSanitizer.maxMessageLength))
    }
}

struct MessageForwardDestination: Identifiable, Hashable {
    let id: String
    let title: String
    let avatarURL: URL?
}

nonisolated enum MessageForwardDestinationPresentation {
    @MainActor
    static func destinations(
        from items: [ChatsListViewModel.Item],
        excludingGroupIdHex currentGroupIdHex: String
    ) -> [MessageForwardDestination] {
        sortedDestinations(
            items.compactMap { item in
                guard item.id != currentGroupIdHex,
                      !item.id.isEmpty,
                      !item.row.pendingConfirmation
                else { return nil }
                return MessageForwardDestination(
                    id: item.id,
                    title: item.title,
                    avatarURL: item.avatarURL
                )
            }
        )
    }

    static func destinations(
        from rows: [ChatListRowFfi],
        excludingGroupIdHex currentGroupIdHex: String
    ) -> [MessageForwardDestination] {
        var seen = Set<String>()
        return sortedDestinations(rows
            .filter { row in
                row.groupIdHex != currentGroupIdHex
                    && !row.groupIdHex.isEmpty
                    && !row.pendingConfirmation
                    && seen.insert(row.groupIdHex).inserted
            }
            .map { row in
                MessageForwardDestination(
                    id: row.groupIdHex,
                    title: ContentSanitizer.groupName(row.groupName)
                        ?? ContentSanitizer.groupName(row.title)
                        ?? IdentityFormatter.short(row.groupIdHex),
                    avatarURL: ContentSanitizer.imageURL(row.avatarUrl)
                )
            }
        )
    }

    private static func sortedDestinations(
        _ destinations: [MessageForwardDestination]
    ) -> [MessageForwardDestination] {
        destinations.sorted { lhs, rhs in
            let comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }
    }
}

struct MessageForwardResult: Equatable {
    let successfulGroupIds: Set<String>
    let failedGroupIds: Set<String>

    var succeededCompletely: Bool {
        !successfulGroupIds.isEmpty && failedGroupIds.isEmpty
    }
}
