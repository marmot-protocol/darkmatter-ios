import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct ChatMuteStoreTests {

    @Test func keyNormalizesCaseAndWhitespace() throws {
        let key = try #require(ChatMuteStore.key(
            accountIdHex: "  ABCDEF01  ",
            groupIdHex: "\tFF00AA11\n"
        ))
        #expect(key == ChatMuteStore.key(accountIdHex: "abcdef01", groupIdHex: "ff00aa11"))
    }

    @Test func keyRejectsBlankComponents() {
        #expect(ChatMuteStore.key(accountIdHex: "", groupIdHex: "ff00") == nil)
        #expect(ChatMuteStore.key(accountIdHex: "   ", groupIdHex: "ff00") == nil)
        #expect(ChatMuteStore.key(accountIdHex: "abcd", groupIdHex: "") == nil)
        #expect(ChatMuteStore.key(accountIdHex: "abcd", groupIdHex: " \n") == nil)
    }

    @Test func keySeparatesAccountsAndGroups() {
        #expect(
            ChatMuteStore.key(accountIdHex: "account-1", groupIdHex: "group-a")
                != ChatMuteStore.key(accountIdHex: "account-2", groupIdHex: "group-a")
        )
        #expect(
            ChatMuteStore.key(accountIdHex: "account-1", groupIdHex: "group-a")
                != ChatMuteStore.key(accountIdHex: "account-1", groupIdHex: "group-b")
        )
        // The separator keeps the account/group boundary unambiguous.
        #expect(
            ChatMuteStore.key(accountIdHex: "ab", groupIdHex: "cd")
                != ChatMuteStore.key(accountIdHex: "abc", groupIdHex: "d")
        )
    }

    @Test func muteRoundTripIsScopedToTheAccountAndGroup() throws {
        let suiteName = "dev.ipf.WhiteNoise.chat-mute-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        ChatMuteStore.setMuted(true, accountIdHex: "account-1", groupIdHex: "group-a", defaults: defaults)

        #expect(ChatMuteStore.isMuted(accountIdHex: "account-1", groupIdHex: "group-a", defaults: defaults))
        #expect(ChatMuteStore.isMuted(accountIdHex: "ACCOUNT-1", groupIdHex: "GROUP-A", defaults: defaults))
        #expect(!ChatMuteStore.isMuted(accountIdHex: "account-2", groupIdHex: "group-a", defaults: defaults))
        #expect(!ChatMuteStore.isMuted(accountIdHex: "account-1", groupIdHex: "group-b", defaults: defaults))

        ChatMuteStore.setMuted(false, accountIdHex: "Account-1", groupIdHex: "Group-A", defaults: defaults)

        #expect(!ChatMuteStore.isMuted(accountIdHex: "account-1", groupIdHex: "group-a", defaults: defaults))
        #expect(ChatMuteStore.mutedChatKeys(defaults: defaults).isEmpty)
    }

    @Test func blankIdentifiersNeverMuteOrMatch() throws {
        let suiteName = "dev.ipf.WhiteNoise.chat-mute-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        ChatMuteStore.setMuted(true, accountIdHex: "", groupIdHex: "group-a", defaults: defaults)

        #expect(ChatMuteStore.mutedChatKeys(defaults: defaults).isEmpty)
        #expect(!ChatMuteStore.isMuted(accountIdHex: "", groupIdHex: "group-a", defaults: defaults))
    }

    @Test func snapshotLookupMatchesStoreReads() throws {
        let suiteName = "dev.ipf.WhiteNoise.chat-mute-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        ChatMuteStore.setMuted(true, accountIdHex: "account-1", groupIdHex: "group-a", defaults: defaults)
        ChatMuteStore.setMuted(true, accountIdHex: "account-2", groupIdHex: "group-b", defaults: defaults)

        let snapshot = ChatMuteStore.mutedChatKeys(defaults: defaults)

        #expect(snapshot.count == 2)
        #expect(ChatMuteStore.isMuted(accountIdHex: "account-1", groupIdHex: "group-a", in: snapshot))
        #expect(ChatMuteStore.isMuted(accountIdHex: "ACCOUNT-2", groupIdHex: "group-b", in: snapshot))
        #expect(!ChatMuteStore.isMuted(accountIdHex: "account-1", groupIdHex: "group-b", in: snapshot))
        #expect(!ChatMuteStore.isMuted(accountIdHex: "", groupIdHex: "group-a", in: snapshot))
    }
}

struct ChatMuteSuppressionPolicyTests {

    @Test func mutedChatIsNeverPresented() {
        #expect(!LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: true,
            isMuted: true,
            appSceneActive: false,
            updateAccountRef: "account-a",
            updateGroupIdHex: "group-a",
            visibleChat: nil
        ))
        #expect(!LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: true,
            isMuted: true,
            appSceneActive: true,
            updateAccountRef: "account-a",
            updateGroupIdHex: "group-a",
            visibleChat: VisibleChatRoute(accountRef: "account-b", groupIdHex: "group-b")
        ))
    }

    @Test func unmutedChatKeepsExistingPresentationBehavior() {
        #expect(LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: true,
            isMuted: false,
            appSceneActive: false,
            updateAccountRef: "account-a",
            updateGroupIdHex: "group-a",
            visibleChat: nil
        ))
    }

    @Test func serviceDecisionSkipsMutedChatsForPrimaryAndAdditionalPresentations() {
        let mutedNewest = muteTestUpdate(
            notificationKey: "muted-newest",
            groupIdHex: "group-muted",
            previewText: "muted message",
            timestampMs: 3_000
        )
        let newerVisible = muteTestUpdate(
            notificationKey: "newer-visible",
            groupIdHex: "group-visible",
            previewText: "second",
            timestampMs: 2_000
        )
        let olderVisible = muteTestUpdate(
            notificationKey: "older-visible",
            groupIdHex: "group-visible",
            previewText: "first",
            timestampMs: 1_000
        )
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: [olderVisible, mutedNewest, newerVisible],
            error: nil
        )
        let mutedChatKeys: Set<String> = [
            ChatMuteStore.key(accountIdHex: mutedNewest.accountIdHex, groupIdHex: "group-muted")!,
        ]

        let decision = NotificationServiceProjection.decision(
            for: collection,
            isMuted: { accountIdHex, groupIdHex in
                ChatMuteStore.isMuted(
                    accountIdHex: accountIdHex,
                    groupIdHex: groupIdHex,
                    in: mutedChatKeys
                )
            }
        )

        #expect(decision == .decorate(
            LocalNotificationProjection.makePresentation(for: newerVisible)!,
            additionalPresentations: [
                LocalNotificationProjection.makePresentation(for: olderVisible)!,
            ]
        ))
    }

    @Test func serviceDecisionDeliversQuietlyWhenEveryPresentableRecordIsMuted() {
        let first = muteTestUpdate(
            notificationKey: "first",
            groupIdHex: "group-muted",
            timestampMs: 1_000
        )
        let second = muteTestUpdate(
            notificationKey: "second",
            groupIdHex: "group-muted",
            timestampMs: 2_000
        )
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: [first, second],
            error: nil
        )
        let mutedChatKeys: Set<String> = [
            ChatMuteStore.key(accountIdHex: first.accountIdHex, groupIdHex: "group-muted")!,
        ]

        let decision = NotificationServiceProjection.decision(
            for: collection,
            isMuted: { accountIdHex, groupIdHex in
                ChatMuteStore.isMuted(
                    accountIdHex: accountIdHex,
                    groupIdHex: groupIdHex,
                    in: mutedChatKeys
                )
            }
        )

        #expect(decision == .deliverQuietly)
    }

    @Test func serviceDecisionStillFallsBackWhenNothingWasPresentableBeforeMuteFiltering() {
        let selfMessage = muteTestUpdate(
            notificationKey: "self",
            groupIdHex: "group-muted",
            isFromSelf: true,
            timestampMs: 1_000
        )
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: [selfMessage],
            error: nil
        )

        let decision = NotificationServiceProjection.decision(
            for: collection,
            isMuted: { _, _ in true }
        )

        #expect(decision == .fallback)
    }

    @Test func serviceDecisionFallsBackOnNoDataEvenWithMutedChats() {
        let collection = BackgroundNotificationCollectionFfi(
            status: .noData,
            notifications: [],
            error: nil
        )

        let decision = NotificationServiceProjection.decision(
            for: collection,
            isMuted: { _, _ in true }
        )

        #expect(decision == .fallback)
    }
}

struct ChatListMuteSwipeActionsTests {

    @Test func unmutedRowOffersMuteOnly() {
        let actions = ChatListSwipeActionsPresentation.leadingActions(isMuted: false)
        #expect(actions.contains(.mute))
        #expect(!actions.contains(.unmute))
    }

    @Test func mutedRowOffersUnmuteOnly() {
        let actions = ChatListSwipeActionsPresentation.leadingActions(isMuted: true)
        #expect(actions.contains(.unmute))
        #expect(!actions.contains(.mute))
    }
}

private func muteTestUpdate(
    notificationKey: String,
    accountRef: String = "account-a",
    accountIdHex: String = String(repeating: "11", count: 32),
    groupIdHex: String,
    previewText: String? = "Hello",
    isFromSelf: Bool = false,
    timestampMs: Int64
) -> NotificationUpdateFfi {
    NotificationUpdateFfi(
        notificationKey: notificationKey,
        conversationKey: "conv-\(groupIdHex)",
        trigger: .newMessage,
        accountRef: accountRef,
        accountIdHex: accountIdHex,
        groupIdHex: groupIdHex,
        groupName: nil,
        isDm: true,
        isMention: false,
        messageIdHex: "message-\(notificationKey)",
        sender: NotificationUserFfi(
            accountIdHex: String(repeating: "22", count: 32),
            displayName: "Alice",
            pictureUrl: nil
        ),
        receiver: NotificationUserFfi(
            accountIdHex: accountIdHex,
            displayName: "Me",
            pictureUrl: nil
        ),
        previewText: previewText,
        reactionEmoji: nil,
        reactedToPreview: nil,
        timestampMs: timestampMs,
        isFromSelf: isFromSelf
    )
}
