import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct AccountUnreadSummaryProjectionTests {

    @MainActor
    @Test func staleFullRefreshPreservesIncrementalUpdateAfterItsBaseline() {
        let account = AccountSummaryFfi(
            label: "account-a",
            accountIdHex: "account-a-id",
            localSigning: true,
            signedOut: false,
            running: true
        )
        let store = AccountUnreadStore()
        store.refreshed(
            from: [AccountUnreadFfi(
                accountIdHex: account.accountIdHex,
                unreadCount: 1,
                unreadConversations: 1,
                hasUnread: true
            )],
            accounts: [account]
        )
        let staleRefreshBaseline = store.incrementalRevisionSnapshot()

        store.update(
            accountIdHex: account.accountIdHex,
            chatListRows: [row(groupIdHex: "fresh", archived: false, unreadCount: 7)],
            accounts: [account]
        )
        store.refreshed(
            from: [AccountUnreadFfi(
                accountIdHex: account.accountIdHex,
                unreadCount: 2,
                unreadConversations: 1,
                hasUnread: true
            )],
            accounts: [account],
            preservingUpdatesAfter: staleRefreshBaseline
        )

        #expect(store.summary(forAccountIdHex: account.accountIdHex)?.unreadCount == 7)
    }

    @Test func summaryMatchesUnarchivedUnreadRows() {
        let summary = AccountUnreadSummaryProjection.summary(
            accountIdHex: "account-a",
            rows: [
                row(groupIdHex: "active-read", archived: false, unreadCount: 0),
                row(groupIdHex: "active-unread-a", archived: false, unreadCount: 2),
                row(groupIdHex: "active-unread-b", archived: false, unreadCount: 5),
                row(groupIdHex: "archived-unread", archived: true, unreadCount: 100),
            ]
        )

        #expect(summary.accountIdHex == "account-a")
        #expect(summary.unreadCount == 7)
        #expect(summary.unreadConversations == 2)
        #expect(summary.hasUnread)
    }

    @Test func summaryPreservesManualOnlyUnreadReminder() {
        let summary = AccountUnreadSummaryProjection.summary(
            accountIdHex: "account-a",
            rows: [
                row(
                    groupIdHex: "manual-reminder",
                    archived: false,
                    unreadCount: 0,
                    hasUnread: true
                ),
            ]
        )

        #expect(summary.unreadCount == 0)
        #expect(summary.unreadConversations == 1)
        #expect(summary.hasUnread)
    }

    @Test func applicationBadgeSumsAccountsAndKeepsManualOnlyAttentionVisible() {
        let count = ApplicationBadgeCountProjection.count(for: [
            AccountUnreadFfi(
                accountIdHex: "account-a",
                unreadCount: 4,
                unreadConversations: 1,
                hasUnread: true
            ),
            AccountUnreadFfi(
                accountIdHex: "account-b",
                unreadCount: 0,
                unreadConversations: 1,
                hasUnread: true
            ),
            AccountUnreadFfi(
                accountIdHex: "account-c",
                unreadCount: 0,
                unreadConversations: 0,
                hasUnread: false
            ),
        ])

        #expect(count == 5)
    }

    @Test func applicationBadgeSaturatesAtPlatformIntegerMaximum() {
        let count = ApplicationBadgeCountProjection.count(for: [
            AccountUnreadFfi(
                accountIdHex: "account-a",
                unreadCount: .max,
                unreadConversations: 1,
                hasUnread: true
            ),
            AccountUnreadFfi(
                accountIdHex: "account-b",
                unreadCount: 1,
                unreadConversations: 1,
                hasUnread: true
            ),
        ])

        #expect(count == Int.max)
    }

    @Test func byAccountIdDropsSummariesForUnknownAccounts() {
        let account = AccountSummaryFfi(
            label: "account-a",
            accountIdHex: "account-a-id",
            localSigning: true,
            signedOut: false,
            running: true
        )

        let result = AccountUnreadSummaryProjection.byAccountId(
            [
                AccountUnreadFfi(
                    accountIdHex: "account-a-id",
                    unreadCount: 3,
                    unreadConversations: 1,
                    hasUnread: true
                ),
                AccountUnreadFfi(
                    accountIdHex: "removed-account-id",
                    unreadCount: 9,
                    unreadConversations: 2,
                    hasUnread: true
                ),
            ],
            accounts: [account]
        )

        #expect(Set(result.keys) == Set(["account-a-id"]))
        #expect(result["account-a-id"]?.unreadCount == 3)
    }

    private func row(
        groupIdHex: String,
        archived: Bool,
        unreadCount: UInt64,
        hasUnread: Bool? = nil
    ) -> ChatListRowFfi {
        ChatListRowFfi(
            groupIdHex: groupIdHex,
            pinned: false,
            pinnedPosition: nil,
            archived: archived,
            pendingConfirmation: false,
            title: groupIdHex,
            groupName: groupIdHex,
            avatarUrl: nil,
            avatar: nil,
            lastMessage: nil,
            unreadCount: unreadCount,
            hasUnread: hasUnread ?? (unreadCount > 0),
            manuallyMarkedUnread: false,
            unreadMentionCount: 0,
            unreadMention: false,
            firstUnreadMessageIdHex: unreadCount > 0 ? "message-\(groupIdHex)" : nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: nil,
            conversationCreatedAt: 1,
            activitySortAt: 1,
            updatedAt: 1,
            selfMembership: .member,
            conversationKind: .group,
            muted: false,
            mutedUntilMs: nil,
            leaveRequestPending: false,
            leaveRequestedAtMs: nil
        )
    }
}
