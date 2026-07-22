import Foundation
import MarmotKit

/// Flow store for the New Message experience. Owns the person directory, the
/// direct-chat starter, and the group-creation selection — the selection
/// lives here (not in the picker screen) so it survives navigating between
/// the picker and setup steps. Each searchable screen owns its own query
/// model so typed text never leaks between steps.
@MainActor
@Observable
final class NewChatFlowViewModel {
    let directory = RecipientDirectory()
    let starter = DirectChatStarter()
    let groupSelection = RecipientSelection()
    let messageQuery = RecipientQueryModel()
    let groupQuery = RecipientQueryModel()

    var startPrompt: StartChatPrompt?
    private(set) var isCreatingGroup = false
    var groupCreateError: String?

#if DEBUG
    @ObservationIgnored var createGroupForTesting: (
        @MainActor (String, String, [String], String?) async throws -> String
    )?
#endif

    var isBusy: Bool { starter.isCreating || isCreatingGroup }

    /// Excludes the active account from every people list in this flow.
    func excludedAccountIds(using appState: AppState) -> Set<String> {
        AddMembersPresentation.excludedNewChatAccountIds(
            activeAccountIdHex: appState.activeAccount?.accountIdHex
        )
    }

    // MARK: - Direct chat

    func startChat(
        accountIdHex: String,
        memberRef: String,
        using appState: AppState,
        onOpen: (String) -> Void
    ) async {
        startPrompt = nil
        // Join any in-flight directory load so the reuse decision can't run
        // against an empty candidate list and create a duplicate direct chat.
        await directory.load(using: appState, force: true)
        let existing = existingDirectChatGroupIdHex(accountIdHex: accountIdHex)
        await runStart(
            accountIdHex: accountIdHex,
            memberRef: memberRef,
            existingGroupIdHex: existing,
            using: appState,
            onOpen: onOpen
        )
    }

    func retryStart(using appState: AppState, onOpen: (String) -> Void) async {
        guard let prompt = startPrompt else { return }
        startPrompt = nil
        await runStart(
            accountIdHex: prompt.accountIdHex,
            memberRef: prompt.memberRef,
            existingGroupIdHex: prompt.existingGroupIdHex,
            using: appState,
            onOpen: onOpen
        )
    }

    private func runStart(
        accountIdHex: String,
        memberRef: String,
        existingGroupIdHex: String?,
        using appState: AppState,
        onOpen: (String) -> Void
    ) async {
        let outcome = await starter.startMapped(
            accountIdHex: accountIdHex,
            memberRef: memberRef,
            existingGroupIdHex: existingGroupIdHex,
            using: appState
        )
        switch outcome {
        case .open(let groupIdHex):
            onOpen(groupIdHex)
        case .prompt(let prompt):
            startPrompt = prompt
        case .ignored:
            break
        }
    }

    private func existingDirectChatGroupIdHex(accountIdHex: String) -> String? {
        let normalized = accountIdHex.lowercased()
        return directory.candidates
            .first { $0.accountIdHex == normalized }?
            .directChatGroupIdHex
    }

    // MARK: - Group selection

    nonisolated static func shouldAutoSelectResolved(
        accountIdHex: String,
        isBusy: Bool,
        excludedAccountIds: Set<String>,
        selectedAccountIds: Set<String>
    ) -> Bool {
        let normalized = accountIdHex.lowercased()
        return !isBusy
            && !excludedAccountIds.contains(normalized)
            && !selectedAccountIds.contains(normalized)
    }

    func toggleSelection(of candidate: RecipientCandidate, using appState: AppState) {
        groupSelection.toggle(
            RecipientSelection.member(for: candidate),
            excludedAccountIds: excludedAccountIds(using: appState)
        )
        if groupSelection.isSelected(accountIdHex: candidate.accountIdHex) {
            groupQuery.clear()
        }
    }

    /// Normalizes a resolved identifier through Marmot before selecting it so
    /// the staged member carries the validated reference form.
    func selectResolved(_ resolved: ResolvedRecipient, using appState: AppState) async {
        do {
            let client = try appState.currentMarmotClient()
            let member = try await client.normalizeMemberRef(memberRef: resolved.memberRef)
            if groupSelection.add(member, excludedAccountIds: excludedAccountIds(using: appState)) {
                Haptics.selection()
                groupQuery.clear()
            }
        } catch {
            Haptics.error()
            appState.present(.error(
                L10n.string("Couldn't add this person"),
                message: error.localizedDescription
            ))
        }
    }

    // MARK: - Group creation

    func createGroup(
        name: String,
        description: String,
        retentionSeconds: UInt64,
        using appState: AppState,
        onOpen: (String) -> Void
    ) async {
        // The in-flight guard is taken synchronously before the first await
        // so a fast double-tap can't start two concurrent creates.
        guard !isCreatingGroup else { return }
        let normalizedName = NewGroupPresentation.normalizedName(name)
        guard let accountRef = appState.activeAccountRef,
              !groupSelection.isEmpty || !normalizedName.isEmpty
        else { return }
        isCreatingGroup = true
        defer { isCreatingGroup = false }
        groupCreateError = nil
        do {
            let normalizedDescription = NewGroupPresentation.normalizedDescription(description)
            let groupIdHex: String
#if DEBUG
            if let createGroupForTesting {
                groupIdHex = try await createGroupForTesting(
                    accountRef,
                    normalizedName,
                    groupSelection.memberRefs,
                    normalizedDescription
                )
            } else {
                let client = try appState.currentMarmotClient()
                groupIdHex = try await client.createGroup(
                    accountRef: accountRef,
                    name: normalizedName,
                    memberRefs: groupSelection.memberRefs,
                    description: normalizedDescription
                )
            }
#else
            let client = try appState.currentMarmotClient()
            groupIdHex = try await client.createGroup(
                accountRef: accountRef,
                name: normalizedName,
                memberRefs: groupSelection.memberRefs,
                description: normalizedDescription
            )
#endif
            if retentionSeconds > 0 {
                let client = try appState.currentMarmotClient()
                await applyRetention(
                    seconds: retentionSeconds,
                    accountRef: accountRef,
                    groupIdHex: groupIdHex,
                    client: client,
                    using: appState
                )
            }
            Haptics.success()
            onOpen(groupIdHex)
        } catch let marmotError as MarmotKitError {
            Haptics.error()
            if case .MissingKeyPackage(let account) = marmotError {
                // Soft validation — keep the flow open and name who can't be added.
                groupCreateError = L10n.formatted(
                    "%@ hasn't published a compatible key package, so they can't be added yet.",
                    IdentityFormatter.short(account)
                )
            } else {
                groupCreateError = marmotError.localizedDescription
                appState.present(.error(
                    L10n.string("Couldn't create chat"),
                    message: marmotError.localizedDescription
                ))
            }
        } catch {
            Haptics.error()
            groupCreateError = error.localizedDescription
            appState.present(.error(L10n.string("Couldn't create chat"), message: error.localizedDescription))
        }
    }

    /// The group exists once creation returns, so a retention failure must
    /// not fail the flow — surface it and continue into the chat.
    private func applyRetention(
        seconds: UInt64,
        accountRef: String,
        groupIdHex: String,
        client: MarmotClient,
        using appState: AppState
    ) async {
        do {
            _ = try await client.updateMessageRetention(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                disappearingMessageSecs: seconds
            )
        } catch {
            appState.present(.warning(
                L10n.string("Disappearing messages weren't applied"),
                message: error.localizedDescription
            ))
        }
    }
}

/// Group metadata normalization shared by the setup step and its tests.
/// An empty name is MarmotKit's unnamed-group sentinel — a one-person unnamed
/// group renders as a direct message, which is the preserved semantic.
nonisolated enum NewGroupPresentation {
    static func normalizedName(_ raw: String) -> String {
        ContentSanitizer.groupName(raw) ?? ""
    }

    static func normalizedDescription(_ raw: String) -> String? {
        ContentSanitizer.multilineText(raw, maxLength: ContentSanitizer.maxGroupDescriptionLength)
    }
}
