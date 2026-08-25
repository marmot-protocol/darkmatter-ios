import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct ChatListPreviewCacheTests {

    @Test func itemCachesSanitizedPreviewAndLowercaseSearchHaystackAtConstruction() {
        let bech32 = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
        let tokens = MarkdownDocumentFfi(blocks: [
            .paragraph(inlines: [
                .text(content: "Hello "),
                .nostrMention(entity: MarkdownNostrEntityFfi(hrp: .npub, bech32: bech32)),
            ]),
        ], truncated: false)
        var resolverCalls = 0

        let item = ChatsListViewModel.Item(
            row: row(
                title: " Team\nRoom ",
                lastMessage: preview(plaintext: "fallback", contentTokens: tokens)
            ),
            avatarURL: nil,
            title: "Team Room",
            mentionDisplayName: { entity in
                resolverCalls += 1
                return entity.bech32 == bech32 ? "ALICE" : nil
            }
        )

        #expect(item.title == "Team Room")
        #expect(item.previewText == "Hello @ALICE")
        #expect(item.searchHaystack.contains("team room"))
        #expect(item.searchHaystack.contains("hello @alice"))

        _ = item.previewText
        _ = item.searchHaystack
        #expect(resolverCalls == 1)
    }

    @Test func chatRowSubtitleDecoratesCachedPreviewTextOnly() {
        let sentItem = ChatsListViewModel.Item(
            row: row(
                lastMessage: preview(sender: "self", plaintext: " hello\nthere ")
            ),
            avatarURL: nil,
            title: "Room"
        )
        #expect(ChatRow.subtitleText(for: sentItem, activeAccountIdHex: "self") == "You: hello there")

        let emptySentItem = ChatsListViewModel.Item(
            row: row(
                lastMessage: preview(sender: "self", plaintext: "   ")
            ),
            avatarURL: nil,
            title: "Room"
        )
        #expect(ChatRow.subtitleText(for: emptySentItem, activeAccountIdHex: "self") == "You sent a message")

        let emptyItem = ChatsListViewModel.Item(row: row(lastMessage: nil), avatarURL: nil, title: "Room")
        #expect(ChatRow.subtitleText(for: emptyItem, activeAccountIdHex: "self") == "No messages yet")
    }

    @Test func groupPreviewUsesProjectedSenderNameWhileDirectMessageDoesNot() {
        let groupItem = ChatsListViewModel.Item(
            row: row(lastMessage: preview(senderDisplayName: " Alice ")),
            avatarURL: nil,
            title: "Room",
            isDirectMessage: false
        )
        let directItem = ChatsListViewModel.Item(
            row: row(lastMessage: preview(senderDisplayName: "Alice")),
            avatarURL: nil,
            title: "Alice",
            isDirectMessage: true
        )

        #expect(ChatRow.previewPresentation(
            for: groupItem,
            activeAccountIdHex: "self",
            senderName: { _ in "Fallback" }
        ) == ChatRowPreviewPresentation(prefix: "Alice", body: "hello"))
        #expect(ChatRow.previewPresentation(
            for: directItem,
            activeAccountIdHex: "self",
            senderName: { _ in "Fallback" }
        ) == ChatRowPreviewPresentation(prefix: nil, body: "hello"))
    }

    @Test func groupSystemActivityDoesNotAddASenderPrefix() {
        let item = ChatsListViewModel.Item(
            row: row(lastMessage: preview(
                sender: "",
                plaintext: #"{"v":1,"system_type":"member_added","text":"Member added"}"#,
                kind: MessageSemantics.kindGroupSystem
            )),
            avatarURL: nil,
            title: "Room",
            isDirectMessage: false
        )

        #expect(ChatRow.previewPresentation(
            for: item,
            activeAccountIdHex: "self",
            senderName: { _ in "Wrong sender" }
        ) == ChatRowPreviewPresentation(prefix: nil, body: "Member added"))
    }

    @Test func terminalMembershipReplacesStaleMessagePreview() {
        let leftItem = ChatsListViewModel.Item(
            row: row(lastMessage: preview(), selfMembership: .left),
            avatarURL: nil,
            title: "Room"
        )
        let removedItem = ChatsListViewModel.Item(
            row: row(lastMessage: preview(), selfMembership: .removed),
            avatarURL: nil,
            title: "Room"
        )

        #expect(ChatRow.subtitleText(for: leftItem, activeAccountIdHex: "self") == "You left this chat.")
        #expect(ChatRow.subtitleText(for: removedItem, activeAccountIdHex: "self") == "You were removed from this chat.")
    }

    @Test func durablePendingLeaveHasDistinctPreviewFromResolvedLeave() {
        let pendingItem = ChatsListViewModel.Item(
            row: row(
                lastMessage: preview(),
                selfMembership: .left,
                leaveRequestPending: true
            ),
            avatarURL: nil,
            title: "Room",
            leaveRequestPending: true
        )

        #expect(ChatRow.subtitleText(for: pendingItem, activeAccountIdHex: "self") == "Leaving…")
        #expect(pendingItem.selfMembership == .left)
        #expect(!pendingItem.isActiveMember)
    }

    private func row(
        groupIdHex: String = "0123456789abcdef",
        title: String = "Room",
        lastMessage: ChatListMessagePreviewFfi? = nil,
        selfMembership: SelfMembershipFfi = .member,
        leaveRequestPending: Bool = false
    ) -> ChatListRowFfi {
        ChatListRowFfi(
            groupIdHex: groupIdHex,
            pinned: false,
            pinnedPosition: nil,
            archived: false,
            pendingConfirmation: false,
            title: title,
            groupName: title,
            avatarUrl: nil,
            avatar: nil,
            lastMessage: lastMessage,
            unreadCount: 0,
            hasUnread: false,
            manuallyMarkedUnread: false,
            unreadMentionCount: 0,
            unreadMention: false,
            firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: nil,
            conversationCreatedAt: 1,
            activitySortAt: 1,
            updatedAt: 1,
            selfMembership: selfMembership,
            conversationKind: .group,
            muted: false,
            mutedUntilMs: nil,
            leaveRequestPending: leaveRequestPending,
            leaveRequestedAtMs: leaveRequestPending ? 1_000 : nil
        )
    }

    private func preview(
        messageIdHex: String = "01",
        sender: String = "sender",
        senderDisplayName: String? = nil,
        plaintext: String = "hello",
        contentTokens: MarkdownDocumentFfi = MarkdownDocumentFfi(blocks: [], truncated: false),
        kind: UInt64 = MessageSemantics.kindChat,
        timelineAt: UInt64 = 1,
        deleted: Bool = false
    ) -> ChatListMessagePreviewFfi {
        ChatListMessagePreviewFfi(
            messageIdHex: messageIdHex,
            sender: sender,
            senderDisplayName: senderDisplayName,
            plaintext: plaintext,
            contentTokens: contentTokens,
            kind: kind,
            timelineAt: timelineAt,
            deleted: deleted
        )
    }
}
