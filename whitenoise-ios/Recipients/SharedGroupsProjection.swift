import Foundation

/// Groups a profile subject shares with the active account: named groups with
/// more than two members where both are on the roster and the viewer is still
/// a member. Direct chats are reached through the Message action instead, and
/// unnamed groups have no stable identity to show. Derived from the same
/// screen-lifetime snapshots the recipient directory loads.
nonisolated enum SharedGroupsProjection {
    struct SharedGroup: Equatable, Identifiable {
        let groupIdHex: String
        let title: String
        let avatarUrl: String?
        let memberCount: Int

        var id: String { groupIdHex }
    }

    static func sharedGroups(
        snapshots: [RecipientGroupSnapshot],
        targetAccountIdHex: String?,
        myAccountIdHex: String?
    ) -> [SharedGroup] {
        guard let target = normalized(targetAccountIdHex), let mine = normalized(myAccountIdHex),
              target != mine
        else { return [] }
        return snapshots
            .filter { snapshot in
                guard snapshot.sanitizedName != nil,
                      snapshot.isSelfMember,
                      snapshot.memberIdsHex.count > 2
                else { return false }
                let roster = Set(snapshot.memberIdsHex.map { $0.lowercased() })
                return roster.contains(target) && roster.contains(mine)
            }
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .map { snapshot in
                SharedGroup(
                    groupIdHex: snapshot.groupIdHex,
                    title: snapshot.title,
                    avatarUrl: snapshot.avatarUrl,
                    memberCount: snapshot.memberIdsHex.count
                )
            }
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
