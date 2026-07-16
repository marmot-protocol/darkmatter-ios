import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct RecipientCandidateDerivationTests {
    private let me = String(repeating: "aa", count: 32)
    private let alice = String(repeating: "bb", count: 32)
    private let bob = String(repeating: "cc", count: 32)
    private let carol = String(repeating: "dd", count: 32)

    @Test func derivesRosterMembersSenderAndWelcomerExcludingSelf() {
        let snapshot = snapshot(
            groupIdHex: "g1",
            name: "Team",
            members: [me, alice],
            lastSender: bob,
            welcomer: carol,
            lastActivityAt: 10
        )

        let candidates = RecipientCandidateDerivation.candidates(from: [snapshot], myAccountIdHex: me)

        #expect(candidates.map(\.accountIdHex) == [alice, bob, carol])
        #expect(candidates.allSatisfy { $0.npub.hasPrefix("npub1") })
    }

    @Test func ordersByMostRecentActivityWithFirstAppearanceFixingPosition() {
        let older = snapshot(groupIdHex: "g1", name: nil, members: [me, alice], lastActivityAt: 5)
        let newer = snapshot(groupIdHex: "g2", name: "Team", members: [me, bob, alice], lastActivityAt: 20)

        let candidates = RecipientCandidateDerivation.candidates(
            from: [older, newer],
            myAccountIdHex: me
        )

        #expect(candidates.map(\.accountIdHex) == [bob, alice])
        #expect(candidates.first { $0.accountIdHex == alice }?.lastActivityAt == 20)
    }

    @Test func detectsOpenUnnamedTwoPersonChatAsReusableDirectChat() {
        let dm = snapshot(groupIdHex: "dm-1", name: nil, members: [me, alice], lastActivityAt: 9)

        let candidates = RecipientCandidateDerivation.candidates(from: [dm], myAccountIdHex: me)

        #expect(candidates.first?.directChatGroupIdHex == "dm-1")
    }

    @Test func namedLeftOrLargerChatsAreNotReusableDirectChats() {
        let named = snapshot(groupIdHex: "g1", name: "Pair", members: [me, alice], lastActivityAt: 9)
        let left = snapshot(
            groupIdHex: "g2",
            name: nil,
            members: [me, alice],
            isSelfMember: false,
            lastActivityAt: 8
        )
        let bigger = snapshot(groupIdHex: "g3", name: nil, members: [me, alice, bob], lastActivityAt: 7)

        let candidates = RecipientCandidateDerivation.candidates(
            from: [named, left, bigger],
            myAccountIdHex: me
        )

        #expect(candidates.first { $0.accountIdHex == alice }?.directChatGroupIdHex == nil)
    }

    @Test func prefersTheMostRecentDirectChatWhenSeveralExist() {
        let older = snapshot(groupIdHex: "dm-old", name: nil, members: [me, alice], lastActivityAt: 5)
        let newer = snapshot(groupIdHex: "dm-new", name: nil, members: [me, alice], lastActivityAt: 15)

        let candidates = RecipientCandidateDerivation.candidates(
            from: [older, newer],
            myAccountIdHex: me
        )

        #expect(candidates.first?.directChatGroupIdHex == "dm-new")
    }

    @Test func ignoresInvalidHexSourcesAndUppercaseNormalizes() {
        let snapshot = snapshot(
            groupIdHex: "g1",
            name: "Team",
            members: [me, alice.uppercased(), "not-hex", ""],
            lastActivityAt: 3
        )

        let candidates = RecipientCandidateDerivation.candidates(from: [snapshot], myAccountIdHex: me)

        #expect(candidates.map(\.accountIdHex) == [alice])
    }

    @Test func countsEachPersonOncePerChat() {
        let one = snapshot(
            groupIdHex: "g1",
            name: "Team",
            members: [me, alice],
            lastSender: alice,
            lastActivityAt: 3
        )
        let two = snapshot(groupIdHex: "g2", name: "Other", members: [me, alice], lastActivityAt: 2)

        let candidates = RecipientCandidateDerivation.candidates(from: [one, two], myAccountIdHex: me)

        #expect(candidates.first?.sharedChatCount == 2)
    }

    @Test func snapshotFromRowKeepsPeerTitleOutOfDirectMessageNameDetection() {
        let row = ChatListRowFfi(
            groupIdHex: "dm-1",
            archived: false,
            pendingConfirmation: false,
            title: "Alice",
            groupName: "",
            avatarUrl: nil,
            avatar: nil,
            lastMessage: nil,
            unreadCount: 0,
            hasUnread: false,
            unreadMentionCount: 0,
            unreadMention: false,
            firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: nil,
            updatedAt: 7,
            selfMembership: .member
        )

        let snapshot = RecipientGroupSnapshot(row: row, details: nil)

        // The row title carries the peer's display name for a direct message;
        // treating it as a group name would make every DM look named.
        #expect(snapshot.sanitizedName == nil)
        #expect(snapshot.title == "Alice")
        #expect(snapshot.lastActivityAt == 7)
        #expect(snapshot.isSelfMember)
    }

    @Test func snapshotRosterUsesMemberIdsInsteadOfLocalAccountLabels() {
        let row = ChatListRowFfi(
            groupIdHex: "dm-1",
            archived: false,
            pendingConfirmation: false,
            title: "Alice",
            groupName: "",
            avatarUrl: nil,
            avatar: nil,
            lastMessage: nil,
            unreadCount: 0,
            hasUnread: false,
            unreadMentionCount: 0,
            unreadMention: false,
            firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: nil,
            updatedAt: 7,
            selfMembership: .member
        )
        let details = GroupDetailsFfi(
            group: AppGroupRecordFfi(
                groupIdHex: "dm-1",
                endpoint: "",
                name: "",
                description: "",
                admins: [],
                relays: [],
                nostrGroupIdHex: "",
                avatarUrl: nil,
                avatarDim: nil,
                avatarThumbhash: nil,
                encryptedMedia: AppGroupEncryptedMediaComponentFfi(
                    componentId: 0,
                    component: "",
                    required: false,
                    mediaFormat: "",
                    allowedLocatorKinds: [],
                    defaultBlobEndpoints: []
                ),
                archived: false,
                pendingConfirmation: false,
                selfMembership: .member,
                welcomerAccountIdHex: nil,
                viaWelcomeMessageIdHex: nil
            ),
            members: [
                member(memberIdHex: me, accountLabel: "primary", isSelf: true),
                member(memberIdHex: alice, accountLabel: nil),
            ]
        )

        let snapshot = RecipientGroupSnapshot(row: row, details: details)
        let candidates = RecipientCandidateDerivation.candidates(
            from: [snapshot],
            myAccountIdHex: me
        )

        #expect(snapshot.memberIdsHex == [me, alice])
        #expect(candidates.map(\.accountIdHex) == [alice])
        #expect(candidates.first?.directChatGroupIdHex == "dm-1")
    }

    private func snapshot(
        groupIdHex: String,
        name: String?,
        members: [String],
        isSelfMember: Bool = true,
        lastSender: String? = nil,
        welcomer: String? = nil,
        lastActivityAt: UInt64
    ) -> RecipientGroupSnapshot {
        RecipientGroupSnapshot(
            groupIdHex: groupIdHex,
            sanitizedName: name,
            title: name ?? groupIdHex,
            avatarUrl: nil,
            isSelfMember: isSelfMember,
            lastActivityAt: lastActivityAt,
            memberIdsHex: members,
            lastSenderIdHex: lastSender,
            welcomerIdHex: welcomer
        )
    }

    private func member(
        memberIdHex: String,
        accountLabel: String?,
        isSelf: Bool = false
    ) -> GroupMemberDetailsFfi {
        GroupMemberDetailsFfi(
            memberIdHex: memberIdHex,
            account: accountLabel,
            local: isSelf,
            isAdmin: false,
            isSelf: isSelf,
            npub: "npub1test",
            displayName: nil
        )
    }
}
