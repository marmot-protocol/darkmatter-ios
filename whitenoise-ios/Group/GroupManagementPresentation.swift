import Foundation
import MarmotKit

nonisolated enum GroupMemberManagementAction: Equatable {
    case remove
    case promote
    case demote
    case selfDemote
}

nonisolated enum GroupManagementPresentation {
    static let inactiveGroupComposerMessage = L10n.string("This group is inactive. You can't send new messages.")
    static let leftGroupComposerMessage = L10n.string("You left the group")
    static let leavingGroupComposerMessage = L10n.string("Leaving group…")

    static func isActiveChatListMember(_ membership: SelfMembershipFfi) -> Bool {
        membership == .member
    }

    static func memberActions(
        for action: GroupMemberActionStateFfi,
        state: GroupManagementStateFfi?
    ) -> [GroupMemberManagementAction] {
        var actions: [GroupMemberManagementAction] = []
        if action.canPromote { actions.append(.promote) }
        if action.canDemote { actions.append(.demote) }
        if action.isSelf, canSelfDemote(state: state) { actions.append(.selfDemote) }
        if action.canRemove { actions.append(.remove) }
        return actions
    }

    static func canInvite(state: GroupManagementStateFfi?, fallbackIsAdmin: Bool) -> Bool {
        state?.canInvite ?? fallbackIsAdmin
    }

    static func isActiveMember(
        state: GroupManagementStateFfi?,
        members: [AppGroupMemberRecordFfi],
        groupMemberDetails: [GroupMemberDetailsFfi],
        myAccountId: String?,
        fallbackSelfMembership: SelfMembershipFfi = .member
    ) -> Bool {
        guard isActiveChatListMember(fallbackSelfMembership) else { return false }

        if let state {
            return !state.leaveRequestPending && (
                state.isSelfAdmin
                || state.canLeave
                || state.requiresSelfDemoteBeforeLeave
                || state.memberActions.contains { $0.isSelf }
            )
        }

        if !groupMemberDetails.isEmpty {
            return groupMemberDetails.contains { member in
                member.isSelf || member.memberIdHex == myAccountId
            }
        }

        if !members.isEmpty {
            return members.contains { member in
                member.local || member.memberIdHex == myAccountId
            }
        }

        return true
    }

    static func canLeave(state: GroupManagementStateFfi?, fallbackIsLastAdmin: Bool) -> Bool {
        if state?.isLastAdmin == true || fallbackIsLastAdmin { return false }
        guard let state else { return !fallbackIsLastAdmin }
        guard !state.leaveRequestPending else { return false }
        return state.canLeave || shouldSelfDemoteBeforeLeave(state: state)
    }

    static func canSelfDemote(state: GroupManagementStateFfi?) -> Bool {
        guard let state else { return false }
        return state.isSelfAdmin && !state.isLastAdmin
    }

    static func shouldSelfDemoteBeforeLeave(state: GroupManagementStateFfi?) -> Bool {
        guard let state else { return false }
        return state.requiresSelfDemoteBeforeLeave && canSelfDemote(state: state)
    }

    static func leaveConfirmationMessage(state: GroupManagementStateFfi?) -> String {
        if shouldSelfDemoteBeforeLeave(state: state) {
            return L10n.string("You'll step down as admin first, then stop receiving messages from this group.")
        }
        return L10n.string("You'll stop receiving messages from this group. Other members will see a system message.")
    }

    static func leaveHelpMessage(
        state: GroupManagementStateFfi?,
        fallbackIsLastAdmin: Bool
    ) -> String {
        if state?.leaveRequestPending == true {
            return leavingGroupComposerMessage
        }
        if state?.isLastAdmin == true || fallbackIsLastAdmin {
            return L10n.string("You're the only admin. Make another member an admin before you leave.")
        }
        return leaveConfirmationMessage(state: state)
    }

    static func leaveFooter(state: GroupManagementStateFfi?, fallbackIsLastAdmin: Bool) -> String? {
        if state?.leaveRequestPending == true {
            return leavingGroupComposerMessage
        }
        if state?.isLastAdmin == true || fallbackIsLastAdmin {
            return L10n.string("You're the only admin. Make another member an admin before you leave.")
        }
        if shouldSelfDemoteBeforeLeave(state: state) {
            return L10n.string("Leaving will step you down as admin first.")
        }
        return nil
    }
}

enum GroupRelaysPresentation {
    static let emptyMessage = L10n.string("No relays configured.")

    static func countLabel(
        for relays: [String],
        locale: Locale = AppLanguage.currentLocale
    ) -> String {
        LocalizedNumberLabel.decimal(UInt64(relays.count), locale: locale)
    }
    static func rows(for relays: [String]) -> [String] {
        guard !relays.isEmpty else { return [emptyMessage] }
        let sanitized = relays.compactMap { ContentSanitizer.relayDisplayLine($0, maxLength: 120) }
        return sanitized.isEmpty ? [emptyMessage] : sanitized
    }
}
