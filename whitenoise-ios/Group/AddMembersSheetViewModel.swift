import Foundation
import MarmotKit

/// Screen store for `AddMembersSheet`: the people directory, the search
/// query, the multi-select, and the invite submission.
@MainActor
@Observable
final class AddMembersSheetViewModel {
    let directory = RecipientDirectory()
    let query = RecipientQueryModel()
    let selection = RecipientSelection()
    var isInviting = false
    var error: String?

    func toggle(_ candidate: RecipientCandidate, excludedAccountIds: Set<String>) {
        selection.toggle(
            RecipientSelection.member(for: candidate),
            excludedAccountIds: excludedAccountIds
        )
        if selection.isSelected(accountIdHex: candidate.accountIdHex) {
            query.clear()
        }
    }

    /// Normalizes a resolved identifier through Marmot before selecting it so
    /// the staged member carries the validated reference form.
    func selectResolved(
        _ resolved: ResolvedRecipient,
        excludedAccountIds: Set<String>,
        normalize: (String) async throws -> MemberRefFfi
    ) async {
        let result = await AddMembersPresentation.normalizedMember(
            resolved.memberRef,
            normalize: normalize
        )
        guard case .normalized(let member) = result else { return }
        if selection.add(member, excludedAccountIds: excludedAccountIds) {
            Haptics.selection()
            query.clear()
        }
    }

    func invite(
        onSubmit: ([String]) async throws -> Void,
        dismiss: () -> Void
    ) async {
        // The in-flight guard is taken synchronously before the first await
        // so a fast double-tap can't start two concurrent invite tasks.
        guard !isInviting, !selection.isEmpty else { return }
        isInviting = true
        error = nil
        do {
            try await onSubmit(selection.memberRefs)
            isInviting = false
            dismiss()
        } catch {
            isInviting = false
            self.error = error.localizedDescription
        }
    }
}
