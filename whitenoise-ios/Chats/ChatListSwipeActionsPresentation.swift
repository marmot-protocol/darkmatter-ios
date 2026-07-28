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
        static let read = Actions(rawValue: 1 << 6)
        static let unread = Actions(rawValue: 1 << 7)
        static let pin = Actions(rawValue: 1 << 8)
        static let unpin = Actions(rawValue: 1 << 9)
    }

    static func leadingActions(
        hasUnread: Bool,
        isPinned: Bool,
        isArchived: Bool
    ) -> Actions {
        var actions: Actions = [hasUnread ? .read : .unread]
        if !isArchived {
            actions.insert(isPinned ? .unpin : .pin)
        }
        return actions
    }

    static func trailingActions(
        isArchived: Bool,
        selfMembership: SelfMembershipFfi,
        leaveRequestPending: Bool,
        isMuted: Bool
    ) -> Actions {
        if leaveRequestPending {
            return isArchived ? [.unarchive] : [.archive]
        }
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
            actions.insert(isMuted ? .unmute : .mute)
        } else {
            actions.insert(.delete)
        }
        return actions
    }
}
