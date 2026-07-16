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

    @Test func keyRejectsSeparatorBearingComponents() {
        // A `:` inside a component would make the account:group join ambiguous
        // (("aa:bb","cc") vs ("aa","bb:cc") would collide), so both are rejected.
        #expect(ChatMuteStore.key(accountIdHex: "aa:bb", groupIdHex: "cc") == nil)
        #expect(ChatMuteStore.key(accountIdHex: "aa", groupIdHex: "bb:cc") == nil)
        #expect(ChatMuteStore.key(accountIdHex: ":", groupIdHex: "cc") == nil)
    }

    @Test func nilSnapshotFailsSafeAsMuted() {
        // A nil snapshot means the shared suite could not be resolved; mute
        // fails safe (muted) so the extension never renders audible content for
        // a chat the user may have silenced.
        #expect(ChatMuteStore.isMuted(accountIdHex: "account-1", groupIdHex: "group-a", snapshot: nil))
        // An empty resolved snapshot is a real read: nothing is muted.
        #expect(!ChatMuteStore.isMuted(accountIdHex: "account-1", groupIdHex: "group-a", snapshot: []))
        let key = ChatMuteStore.key(accountIdHex: "account-1", groupIdHex: "group-a")!
        #expect(ChatMuteStore.isMuted(accountIdHex: "account-1", groupIdHex: "group-a", snapshot: [key]))
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
            notifyMode: .nothing,
            appSceneActive: false,
            updateAccountRef: "account-a",
            updateGroupIdHex: "group-a",
            visibleChat: nil
        ))
        #expect(!LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: true,
            notifyMode: .nothing,
            appSceneActive: true,
            updateAccountRef: "account-a",
            updateGroupIdHex: "group-a",
            visibleChat: VisibleChatRoute(accountRef: "account-b", groupIdHex: "group-b")
        ))
    }

    @Test func unmutedChatKeepsExistingPresentationBehavior() {
        #expect(LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: true,
            notifyMode: .all,
            appSceneActive: false,
            updateAccountRef: "account-a",
            updateGroupIdHex: "group-a",
            visibleChat: nil
        ))
    }

    @Test func mentionsOnlyPresentsOnlyMentions() {
        #expect(!LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: true,
            notifyMode: .mentionsOnly,
            isMention: false,
            appSceneActive: false,
            updateAccountRef: "account-a",
            updateGroupIdHex: "group-a",
            visibleChat: nil
        ))
        #expect(LocalNotificationSuppressionPolicy.shouldPresent(
            localNotificationsEnabled: true,
            notifyMode: .mentionsOnly,
            isMention: true,
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
            notifyMode: { accountIdHex, groupIdHex in
                ChatMuteStore.isMuted(
                    accountIdHex: accountIdHex,
                    groupIdHex: groupIdHex,
                    in: mutedChatKeys
                ) ? .nothing : .all
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
            notifyMode: { accountIdHex, groupIdHex in
                ChatMuteStore.isMuted(
                    accountIdHex: accountIdHex,
                    groupIdHex: groupIdHex,
                    in: mutedChatKeys
                ) ? .nothing : .all
            }
        )

        #expect(decision == .deliverQuietly)
    }

    @Test func serviceDecisionDeliversQuietlyWhenTheWakeOnlyCarriedSelfMessages() {
        // The wake had records, every one suppressed — quiet beats an audible
        // generic banner for content the user's own devices produced.
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
            notifyMode: { _, _ in .nothing }
        )

        #expect(decision == .deliverQuietly)
    }

    @Test func serviceDecisionDeliversQuietlyWhenLocalNotificationsAreDisabled() {
        // Native push on + local notifications off must not produce an
        // audible generic banner per message (#675); the functionally
        // identical all-muted wake already delivered quietly.
        let update = muteTestUpdate(
            notificationKey: "plain",
            groupIdHex: "group-quiet",
            timestampMs: 1_000
        )
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: [update],
            error: nil
        )

        let decision = NotificationServiceProjection.decision(
            for: collection,
            localNotificationsEnabled: { _ in false }
        )

        #expect(decision == .deliverQuietly)
    }

    @Test func serviceDecisionInMentionsOnlyModeKeepsMentionsAndQuietsTheRest() {
        let mention = muteTestUpdate(
            notificationKey: "mention",
            groupIdHex: "group-mentions",
            isMention: true,
            timestampMs: 2_000
        )
        let plain = muteTestUpdate(
            notificationKey: "plain",
            groupIdHex: "group-mentions",
            timestampMs: 1_000
        )
        let collection = BackgroundNotificationCollectionFfi(
            status: .newData,
            notifications: [plain, mention],
            error: nil
        )

        let decision = NotificationServiceProjection.decision(
            for: collection,
            notifyMode: { _, _ in .mentionsOnly }
        )

        #expect(decision == .decorate(
            LocalNotificationProjection.makePresentation(for: mention)!,
            additionalPresentations: []
        ))

        let quietDecision = NotificationServiceProjection.decision(
            for: BackgroundNotificationCollectionFfi(
                status: .newData,
                notifications: [plain],
                error: nil
            ),
            notifyMode: { _, _ in .mentionsOnly }
        )
        #expect(quietDecision == .deliverQuietly)
    }

    @Test func serviceDecisionFallsBackOnNoDataEvenWithMutedChats() {
        let collection = BackgroundNotificationCollectionFfi(
            status: .noData,
            notifications: [],
            error: nil
        )

        let decision = NotificationServiceProjection.decision(
            for: collection,
            notifyMode: { _, _ in .nothing }
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

struct ChatNotifyModeStoreTests {
    private func isolatedDefaults() throws -> (UserDefaults, String) {
        let suiteName = "chat-notify-mode-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    @Test func modeDefaultsToAllAndInheritsLegacyMute() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let account = String(repeating: "11", count: 32)

        var snapshot = ChatMuteStore.notifyModeSnapshot(defaults: defaults)
        #expect(ChatMuteStore.notifyMode(accountIdHex: account, groupIdHex: "group-a", in: snapshot) == .all)

        // A chat muted before the tri-state existed reads as Nothing.
        ChatMuteStore.setMuted(true, accountIdHex: account, groupIdHex: "group-a", defaults: defaults)
        snapshot = ChatMuteStore.notifyModeSnapshot(defaults: defaults)
        #expect(ChatMuteStore.notifyMode(accountIdHex: account, groupIdHex: "group-a", in: snapshot) == .nothing)
    }

    @Test func explicitModeOutranksLegacyMuteAndWritesThrough() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let account = String(repeating: "11", count: 32)

        ChatMuteStore.setNotifyMode(.mentionsOnly, accountIdHex: account, groupIdHex: "group-a", defaults: defaults)
        var snapshot = ChatMuteStore.notifyModeSnapshot(defaults: defaults)
        #expect(ChatMuteStore.notifyMode(accountIdHex: account, groupIdHex: "group-a", in: snapshot) == .mentionsOnly)
        // Write-through keeps the legacy set consistent: mentions-only is not muted.
        #expect(!ChatMuteStore.isMuted(accountIdHex: account, groupIdHex: "group-a", defaults: defaults))

        ChatMuteStore.setNotifyMode(.nothing, accountIdHex: account, groupIdHex: "group-a", defaults: defaults)
        snapshot = ChatMuteStore.notifyModeSnapshot(defaults: defaults)
        #expect(ChatMuteStore.notifyMode(accountIdHex: account, groupIdHex: "group-a", in: snapshot) == .nothing)
        #expect(ChatMuteStore.isMuted(accountIdHex: account, groupIdHex: "group-a", defaults: defaults))
    }

    @Test func nilSnapshotFailsSafeAsNothing() {
        #expect(ChatMuteStore.notifyMode(
            accountIdHex: String(repeating: "11", count: 32),
            groupIdHex: "group-a",
            snapshot: nil
        ) == .nothing)
    }

    @Test func modeIsScopedToTheAccountAndGroup() throws {
        let (defaults, suiteName) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let accountA = String(repeating: "11", count: 32)
        let accountB = String(repeating: "22", count: 32)

        ChatMuteStore.setNotifyMode(.mentionsOnly, accountIdHex: accountA, groupIdHex: "group-a", defaults: defaults)
        let snapshot = ChatMuteStore.notifyModeSnapshot(defaults: defaults)
        #expect(ChatMuteStore.notifyMode(accountIdHex: accountB, groupIdHex: "group-a", in: snapshot) == .all)
        #expect(ChatMuteStore.notifyMode(accountIdHex: accountA, groupIdHex: "group-b", in: snapshot) == .all)
    }
}

private func muteTestUpdate(
    notificationKey: String,
    accountRef: String = "account-a",
    accountIdHex: String = String(repeating: "11", count: 32),
    groupIdHex: String,
    previewText: String? = "Hello",
    isFromSelf: Bool = false,
    isMention: Bool = false,
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
        isMention: isMention,
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
