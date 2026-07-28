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
    @ObservationIgnored var existingDirectChatGroupIdForTesting: (
        @MainActor (String) async throws -> String?
    )?
    @ObservationIgnored var createGroupForTesting: (
        @MainActor (String, String, [String], String?) async throws -> String
    )?
    @ObservationIgnored var createGroupWithInitialImageForTesting: (
        @MainActor (String, String, [String], String?, InitialGroupImageFfi) async throws -> String
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
        let existing: String?
        do {
            existing = try await existingDirectChatGroupIdHex(
                accountIdHex: accountIdHex,
                using: appState
            )
        } catch is CancellationError {
            return
        } catch {
            Haptics.error()
            startPrompt = StartChatPrompt(
                kind: .error(message: error.localizedDescription),
                recipientName: appState.knownDisplayName(forAccountIdHex: accountIdHex),
                accountIdHex: accountIdHex,
                memberRef: memberRef,
                existingGroupIdHex: nil
            )
            return
        }
        guard !Task.isCancelled else { return }
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
        await startChat(
            accountIdHex: prompt.accountIdHex,
            memberRef: prompt.memberRef,
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

    private func existingDirectChatGroupIdHex(
        accountIdHex: String,
        using appState: AppState
    ) async throws -> String? {
        let normalized = accountIdHex.lowercased()
#if DEBUG
        if let existingDirectChatGroupIdForTesting {
            return try await existingDirectChatGroupIdForTesting(normalized)
        }
#endif
        guard let accountRef = appState.activeAccountRef,
              let myAccountIdHex = appState.activeAccount?.accountIdHex
        else {
            throw DirectChatLookupError.noActiveAccount
        }
        let client = try appState.currentMarmotClient()
        let rows = try await client.chatList(accountRef: accountRef, includeArchived: true)
        let candidates = rows
            .filter {
                DirectChatReuseLookup.shouldInspect(
                    conversationKind: $0.conversationKind,
                    selfMembership: $0.selfMembership
                )
            }
            .sorted { $0.activitySortAt > $1.activitySortAt }

        var snapshots: [RecipientGroupSnapshot] = []
        var firstReadError: Error?
        for row in candidates {
            try Task.checkCancellation()
            do {
                let details = try await client.groupDetails(
                    accountRef: accountRef,
                    groupIdHex: row.groupIdHex
                )
                snapshots.append(RecipientGroupSnapshot(row: row, details: details))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                firstReadError = firstReadError ?? error
            }
        }

        if let existing = DirectChatReuseLookup.existingGroupId(
            in: snapshots,
            targetAccountIdHex: normalized,
            myAccountIdHex: myAccountIdHex
        ) {
            return existing
        }
        if let firstReadError {
            throw firstReadError
        }
        return nil
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
        image: GroupImageUploadDraft? = nil,
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
            if let image, let createGroupWithInitialImageForTesting {
                groupIdHex = try await createGroupWithInitialImageForTesting(
                    accountRef,
                    normalizedName,
                    groupSelection.memberRefs,
                    normalizedDescription,
                    image.initialImage
                )
            } else if image == nil, let createGroupForTesting {
                groupIdHex = try await createGroupForTesting(
                    accountRef,
                    normalizedName,
                    groupSelection.memberRefs,
                    normalizedDescription
                )
            } else {
                let client = try appState.currentMarmotClient()
                groupIdHex = try await client.createGroupWithInitialImage(
                    accountRef: accountRef,
                    name: normalizedName,
                    memberRefs: groupSelection.memberRefs,
                    description: normalizedDescription,
                    initialImage: image?.initialImage
                )
            }
#else
            let client = try appState.currentMarmotClient()
            groupIdHex = try await client.createGroupWithInitialImage(
                accountRef: accountRef,
                name: normalizedName,
                memberRefs: groupSelection.memberRefs,
                description: normalizedDescription,
                initialImage: image?.initialImage
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

private nonisolated enum DirectChatLookupError: LocalizedError {
    case noActiveAccount

    var errorDescription: String? {
        L10n.string("No active account is selected.")
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
