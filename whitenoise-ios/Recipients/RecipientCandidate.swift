import Foundation
import MarmotKit

/// One person reachable from the active account's current Marmot-backed chat
/// state. Derived on demand — never persisted — so Marmot stays the only
/// durable store of who the user talks to.
nonisolated struct RecipientCandidate: Equatable, Identifiable {
    let accountIdHex: String
    let npub: String
    /// Newest activity timestamp across every group this person appears in.
    let lastActivityAt: UInt64
    /// Group id of the most recent open unnamed two-person chat with this
    /// person, when one exists. Tapping the person reopens it instead of
    /// creating a duplicate.
    let directChatGroupIdHex: String?
    /// How many chats this person appears in (identity context).
    let sharedChatCount: Int

    var id: String { accountIdHex }
}

/// Screen-lifetime projection of one chat-list row plus its member roster,
/// the minimal inputs candidate derivation and shared-group projection need.
nonisolated struct RecipientGroupSnapshot: Equatable {
    let groupIdHex: String
    /// Sanitized group name; `nil` means unnamed. The row `title` is not a
    /// fallback here — for a direct message it carries the peer's name, which
    /// would make every unnamed two-person chat look like a named group.
    let sanitizedName: String?
    let title: String
    let avatarUrl: String?
    let imageHashHex: String?
    let isSelfMember: Bool
    let conversationKind: ChatConversationKindFfi
    let lastActivityAt: UInt64
    let memberIdsHex: [String]
    let lastSenderIdHex: String?
    let welcomerIdHex: String?
    /// Group admins, for "can I add someone to this group" projections.
    let adminIdsHex: [String]

    init(row: ChatListRowFfi, details: GroupDetailsFfi?) {
        self.init(
            groupIdHex: row.groupIdHex,
            sanitizedName: ContentSanitizer.groupName(details?.group.name ?? row.groupName),
            title: ContentSanitizer.groupName(row.groupName)
                ?? ContentSanitizer.groupName(row.title)
                ?? IdentityFormatter.short(row.groupIdHex),
            avatarUrl: details?.group.avatarUrl ?? row.avatarUrl,
            imageHashHex: details?.group.imageHashHex ?? row.avatar?.imageHashHex,
            isSelfMember: GroupManagementPresentation.isActiveChatListMember(row.selfMembership),
            conversationKind: row.conversationKind,
            lastActivityAt: row.lastMessage?.timelineAt ?? row.updatedAt,
            memberIdsHex: details?.members.map(GroupMemberDetailsPresentation.profileAccountIdHex) ?? [],
            lastSenderIdHex: row.lastMessage?.sender,
            welcomerIdHex: details?.group.welcomerAccountIdHex,
            adminIdsHex: details?.group.admins ?? []
        )
    }

    init(
        groupIdHex: String,
        sanitizedName: String?,
        title: String,
        avatarUrl: String?,
        imageHashHex: String? = nil,
        isSelfMember: Bool,
        conversationKind: ChatConversationKindFfi = .unknown,
        lastActivityAt: UInt64,
        memberIdsHex: [String],
        lastSenderIdHex: String?,
        welcomerIdHex: String?,
        adminIdsHex: [String] = []
    ) {
        self.groupIdHex = groupIdHex
        self.sanitizedName = sanitizedName
        self.title = title
        self.avatarUrl = avatarUrl
        self.imageHashHex = imageHashHex
        self.isSelfMember = isSelfMember
        self.conversationKind = conversationKind
        self.lastActivityAt = lastActivityAt
        self.memberIdsHex = memberIdsHex
        self.lastSenderIdHex = lastSenderIdHex
        self.welcomerIdHex = welcomerIdHex
        self.adminIdsHex = adminIdsHex
    }

    /// An open, unnamed two-person chat — the only kind a person-tap may
    /// reuse. Renamed or left conversations don't count, matching how the
    /// chats list renders direct messages.
    func isDirectChat(withMember targetIdHex: String, myAccountIdHex: String) -> Bool {
        guard conversationKind != .group,
              sanitizedName == nil,
              isSelfMember,
              memberIdsHex.count == 2
        else { return false }
        let normalized = Set(memberIdsHex.map { $0.lowercased() })
        return normalized == [targetIdHex.lowercased(), myAccountIdHex.lowercased()]
    }
}

nonisolated enum DirectChatReuseLookup {
    static func shouldInspect(
        conversationKind: ChatConversationKindFfi,
        selfMembership: SelfMembershipFfi
    ) -> Bool {
        GroupManagementPresentation.isActiveChatListMember(selfMembership)
            && conversationKind != .group
    }

    static func existingGroupId(
        in snapshots: [RecipientGroupSnapshot],
        targetAccountIdHex: String,
        myAccountIdHex: String
    ) -> String? {
        snapshots
            .filter {
                $0.isDirectChat(
                    withMember: targetAccountIdHex,
                    myAccountIdHex: myAccountIdHex
                )
            }
            .max { $0.lastActivityAt < $1.lastActivityAt }?
            .groupIdHex
    }
}

nonisolated enum RecipientCandidateDerivation {
    /// Derives people from chat snapshots, newest conversation activity first.
    /// Every roster member, last-message sender, and group welcomer is a
    /// source; the active account is excluded and the first (most recent)
    /// appearance fixes a person's position.
    static func candidates(
        from snapshots: [RecipientGroupSnapshot],
        myAccountIdHex: String?
    ) -> [RecipientCandidate] {
        let myHex = myAccountIdHex?.lowercased()
        let recencyOrdered = snapshots.sorted { $0.lastActivityAt > $1.lastActivityAt }

        var order: [String] = []
        var lastActivity: [String: UInt64] = [:]
        var directChat: [String: String] = [:]
        var sharedCount: [String: Int] = [:]
        var npubs: [String: String] = [:]

        for snapshot in recencyOrdered {
            var seenInThisGroup: Set<String> = []
            let note = { (rawHex: String?) in
                guard let rawHex else { return }
                let hex = rawHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                guard Hex.is32Bytes(hex), hex != myHex else { return }
                guard let npub = npubs[hex] ?? NostrProfileReference.npub(fromAccountIdHex: hex) else { return }
                npubs[hex] = npub
                if lastActivity[hex] == nil {
                    order.append(hex)
                    lastActivity[hex] = snapshot.lastActivityAt
                }
                if seenInThisGroup.insert(hex).inserted {
                    sharedCount[hex, default: 0] += 1
                }
                if directChat[hex] == nil, let myHex,
                   snapshot.isDirectChat(withMember: hex, myAccountIdHex: myHex) {
                    directChat[hex] = snapshot.groupIdHex
                }
            }

            for member in snapshot.memberIdsHex {
                note(member)
            }
            note(snapshot.lastSenderIdHex)
            note(snapshot.welcomerIdHex)
        }

        return order.map { hex in
            RecipientCandidate(
                accountIdHex: hex,
                npub: npubs[hex] ?? hex,
                lastActivityAt: lastActivity[hex] ?? 0,
                directChatGroupIdHex: directChat[hex],
                sharedChatCount: sharedCount[hex] ?? 0
            )
        }
    }
}
