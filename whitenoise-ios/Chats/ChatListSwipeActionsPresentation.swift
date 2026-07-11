import MarmotKit

/// Pure swipe-action policy for chat-list rows (#345). Inactive memberships
/// (`left` / `removed`) keep archive controls but swap leave for local delete.
nonisolated enum ChatListSwipeActionsPresentation: Equatable {
    nonisolated struct Actions: OptionSet, Equatable {
        let rawValue: Int

        static let leave = Actions(rawValue: 1 << 0)
        static let archive = Actions(rawValue: 1 << 1)
        static let unarchive = Actions(rawValue: 1 << 2)
        static let delete = Actions(rawValue: 1 << 3)
        static let mute = Actions(rawValue: 1 << 4)
        static let unmute = Actions(rawValue: 1 << 5)
    }

    /// Mute is per-device presentation state, so it stays available regardless
    /// of archive state or membership.
    static func leadingActions(isMuted: Bool) -> Actions {
        isMuted ? [.unmute] : [.mute]
    }

    static func trailingActions(
        isArchived: Bool,
        selfMembership: SelfMembershipFfi
    ) -> Actions {
        let isActiveMember = GroupManagementPresentation.isActiveChatListMember(selfMembership)
        if isArchived {
            var actions: Actions = [.unarchive]
            if isActiveMember {
                actions.insert(.leave)
            } else {
                actions.insert(.delete)
            }
            return actions
        }

        var actions: Actions = [.archive]
        if isActiveMember {
            actions.insert(.leave)
        } else {
            actions.insert(.delete)
        }
        return actions
    }
}
