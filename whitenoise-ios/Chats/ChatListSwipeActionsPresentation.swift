import MarmotKit

/// Pure swipe-action policy for chat-list rows (#345). Inactive memberships
/// (`left` / `removed`) keep archive controls but swap leave for local delete.
enum ChatListSwipeActionsPresentation: Equatable {
    struct Actions: OptionSet, Equatable {
        let rawValue: Int

        static let leave = Actions(rawValue: 1 << 0)
        static let archive = Actions(rawValue: 1 << 1)
        static let unarchive = Actions(rawValue: 1 << 2)
        static let delete = Actions(rawValue: 1 << 3)
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
