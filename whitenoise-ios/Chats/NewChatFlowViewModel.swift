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
    let messageUserSearch = RecipientUserSearch()
    let groupUserSearch = RecipientUserSearch()

    var startPrompt: StartChatPrompt?
    var conversationChooser: ConversationChooserPresentation?
    private(set) var choosingAccountIdHex: String?
    private(set) var isCreatingGroup = false
    var groupCreateError: String?
    private var retryStartMode = RetryStartMode.canonicalLookup

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

    var isBusy: Bool {
        choosingAccountIdHex != nil || starter.isCreating || isCreatingGroup
    }

    /// Excludes the active account from every people list in this flow.
    func excludedAccountIds(using appState: AppState) -> Set<String> {
        AddMembersPresentation.excludedNewChatAccountIds(
            activeAccountIdHex: appState.activeAccount?.accountIdHex
        )
    }

    // MARK: - Direct chat

    /// Person-selection entry point. Existing exact two-person conversations
    /// are offered explicitly; otherwise the first conversation is created.
    func chooseConversation(
        accountIdHex: String,
        memberRef: String,
        using appState: AppState,
        onOpen: (String) -> Void
    ) async {
        guard choosingAccountIdHex == nil else { return }
        retryStartMode = .conversationChoiceLookup
        startPrompt = nil
        conversationChooser = nil
        choosingAccountIdHex = accountIdHex
        defer { choosingAccountIdHex = nil }

        guard let myAccountIdHex = appState.activeAccount?.accountIdHex else {
            presentChoiceLookupError(
                L10n.string("No active account is selected."),
                accountIdHex: accountIdHex,
                memberRef: memberRef,
                using: appState
            )
            return
        }

        await directory.load(using: appState, force: true)
        guard !Task.isCancelled else { return }
        if let loadError = directory.loadError {
            presentChoiceLookupError(
                loadError,
                accountIdHex: accountIdHex,
                memberRef: memberRef,
                using: appState
            )
            return
        }

        let choices = ConversationChoiceProjection.choices(
            in: directory.snapshots,
            targetAccountIdHex: accountIdHex,
            myAccountIdHex: myAccountIdHex
        )
        guard !choices.isEmpty else {
            await runStart(
                accountIdHex: accountIdHex,
                memberRef: memberRef,
                existingGroupIdHex: nil,
                failureRetryMode: .exact,
                using: appState,
                onOpen: onOpen
            )
            return
        }

        conversationChooser = ConversationChooserPresentation(
            targetAccountIdHex: accountIdHex,
            memberRef: memberRef,
            recipientName: appState.knownDisplayName(forAccountIdHex: accountIdHex)
                ?? IdentityFormatter.short(memberRef),
            choices: choices
        )
        Haptics.selection()
    }

    func openConversation(
        _ choice: ConversationChoice,
        using appState: AppState,
        onOpen: (String) -> Void
    ) async {
        guard let chooser = conversationChooser else { return }
        conversationChooser = nil
        await runStart(
            accountIdHex: chooser.targetAccountIdHex,
            memberRef: chooser.memberRef,
            existingGroupIdHex: choice.groupIdHex,
            failureRetryMode: .exact,
            using: appState,
            onOpen: onOpen
        )
    }

    func startNewConversation(
        using appState: AppState,
        onOpen: (String) -> Void
    ) async {
        guard let chooser = conversationChooser else { return }
        conversationChooser = nil
        await runStart(
            accountIdHex: chooser.targetAccountIdHex,
            memberRef: chooser.memberRef,
            existingGroupIdHex: nil,
            failureRetryMode: .exact,
            using: appState,
            onOpen: onOpen
        )
    }

    /// Canonical single-chat entry point retained for surfaces such as White
    /// Noise Support, where opening the existing chat is always the intent.
    func startChat(
        accountIdHex: String,
        memberRef: String,
        using appState: AppState,
        onOpen: (String) -> Void
    ) async {
        retryStartMode = .canonicalLookup
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
            failureRetryMode: .canonicalLookup,
            using: appState,
            onOpen: onOpen
        )
    }

    private func presentChoiceLookupError(
        _ message: String,
        accountIdHex: String,
        memberRef: String,
        using appState: AppState
    ) {
        Haptics.error()
        startPrompt = StartChatPrompt(
            kind: .error(message: message),
            recipientName: appState.knownDisplayName(forAccountIdHex: accountIdHex),
            accountIdHex: accountIdHex,
            memberRef: memberRef,
            existingGroupIdHex: nil
        )
    }

    func retryStart(using appState: AppState, onOpen: (String) -> Void) async {
        guard let prompt = startPrompt else { return }
        switch retryStartMode {
        case .canonicalLookup:
            await startChat(
                accountIdHex: prompt.accountIdHex,
                memberRef: prompt.memberRef,
                using: appState,
                onOpen: onOpen
            )
        case .conversationChoiceLookup:
            await chooseConversation(
                accountIdHex: prompt.accountIdHex,
                memberRef: prompt.memberRef,
                using: appState,
                onOpen: onOpen
            )
        case .exact:
            startPrompt = nil
            await runStart(
                accountIdHex: prompt.accountIdHex,
                memberRef: prompt.memberRef,
                existingGroupIdHex: prompt.existingGroupIdHex,
                failureRetryMode: .exact,
                using: appState,
                onOpen: onOpen
            )
        }
    }

    private func runStart(
        accountIdHex: String,
        memberRef: String,
        existingGroupIdHex: String?,
        failureRetryMode: RetryStartMode,
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
            retryStartMode = failureRetryMode
            startPrompt = prompt
        case .ignored:
            break
        }
    }

    private enum RetryStartMode {
        case canonicalLookup
        case conversationChoiceLookup
        case exact
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
            appState.present(UserFacingError.toast(title: L10n.string("Couldn't add this person"), error: error))
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
                appState.present(UserFacingError.toast(title: L10n.string("Couldn't create chat"), error: marmotError))
            }
        } catch {
            Haptics.error()
            groupCreateError = error.localizedDescription
            appState.present(UserFacingError.toast(title: L10n.string("Couldn't create chat"), error: error))
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
                message: L10n.string("Retry")
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
