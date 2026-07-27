import Testing

@testable import whitenoise_ios

@MainActor
struct ChatListLeaveActionStateTests {
    @Test func cancellationNeverEntersTheLeavePhase() {
        let state = ChatListLeaveActionState()
        let target = ChatListLeavePresentation.Target(
            groupIdHex: "group-id",
            title: "Alice"
        )

        #expect(state.beginPreparation(for: target))
        #expect(state.preparingGroupIds == ["group-id"])
        #expect(state.leavingGroupIds.isEmpty)

        state.finishPreparation(for: target, canPresentConfirmation: true)
        #expect(state.pendingConfirmation == target)
        #expect(state.leavingGroupIds.isEmpty)

        state.cancelConfirmation()
        #expect(state.pendingConfirmation == nil)
        #expect(state.leavingGroupIds.isEmpty)
    }

    @Test func destructiveConfirmationOwnsTheLeavePhase() {
        let state = ChatListLeaveActionState()
        let target = ChatListLeavePresentation.Target(
            groupIdHex: "group-id",
            title: "A very long localized direct-message title"
        )

        #expect(state.beginPreparation(for: target))
        state.finishPreparation(for: target, canPresentConfirmation: true)
        #expect(state.beginConfirmedLeave(for: target))
        #expect(state.pendingConfirmation == nil)
        #expect(state.leavingGroupIds == ["group-id"])
        #expect(!state.beginPreparation(for: target))

        state.finishLeave(groupIdHex: target.groupIdHex)
        #expect(state.leavingGroupIds.isEmpty)
    }

    @Test func ineligiblePreparationDoesNotPresentOrLeave() {
        let state = ChatListLeaveActionState()
        let target = ChatListLeavePresentation.Target(
            groupIdHex: "group-id",
            title: "Team"
        )

        #expect(state.beginPreparation(for: target))
        state.finishPreparation(for: target, canPresentConfirmation: false)

        #expect(state.pendingConfirmation == nil)
        #expect(state.preparingGroupIds.isEmpty)
        #expect(state.leavingGroupIds.isEmpty)
    }

    @Test func onlyOneChatCanOwnThePendingConfirmation() {
        let state = ChatListLeaveActionState()
        let first = ChatListLeavePresentation.Target(groupIdHex: "first", title: "First")
        let second = ChatListLeavePresentation.Target(groupIdHex: "second", title: "Second")

        #expect(state.beginPreparation(for: first))
        #expect(!state.beginPreparation(for: second))

        state.finishPreparation(for: first, canPresentConfirmation: true)
        #expect(state.pendingConfirmation == first)
        #expect(!state.beginPreparation(for: second))

        state.cancelConfirmation()
        #expect(state.beginPreparation(for: second))
    }

    @Test func confirmationCopyNamesTheChatAndFailureCopyIsGeneric() {
        let target = ChatListLeavePresentation.Target(
            groupIdHex: "group-id",
            title: "Alice"
        )

        #expect(ChatListLeavePresentation.confirmationTitle(for: target) == "Leave “Alice”?")
        #expect(
            ChatListLeavePresentation.confirmationMessage
                == "You'll stop receiving new messages. This chat will remain on this device as read-only history until you delete it."
        )
        #expect(ChatListLeavePresentation.failureTitle == "Couldn't leave chat")
        #expect(ChatListLeavePresentation.failureMessage == "Try again.")
    }
}
