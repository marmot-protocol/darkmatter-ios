import Foundation
import MarmotKit

/// Screen store for the profile surface: resolves the profile reference to
/// an account id, derives shared groups from chat state, runs the Message
/// action through the shared direct-chat starter (so the invite/retry path
/// matches New Message), and independently verifies a declared NIP-05
/// address before any verified state is shown.
@MainActor
@Observable
final class ProfileViewModel {
    var hex: String?
    var startPrompt: StartChatPrompt?
    private(set) var sharedGroups: [SharedGroupsProjection.SharedGroup] = []
    private(set) var verifiedNip05: String?

    let starter = DirectChatStarter()
    let directory = RecipientDirectory()
    private var attemptedNip05Verification: String?

    func resolve(npub: String, using appState: AppState) async {
        guard let reference = ProfileReferenceResolution.referenceForResolution(npub) else {
            hex = nil
            return
        }
        guard let client = try? appState.currentMarmotClient() else { return }
        let resolvedHex = await client.accountIdHex(reference: reference)
        guard !Task.isCancelled else { return }
        hex = resolvedHex
        guard let resolvedHex else { return }
        // Trigger enrichment (cached read + background relay fetch).
        _ = appState.profile(forAccountIdHex: resolvedHex)
        await directory.load(using: appState)
        guard !Task.isCancelled else { return }
        sharedGroups = SharedGroupsProjection.sharedGroups(
            snapshots: directory.snapshots,
            targetAccountIdHex: resolvedHex,
            myAccountIdHex: appState.activeAccount?.accountIdHex
        )
    }

    /// One bounded lookup per declared address; the verified state appears
    /// only when the declaration independently resolves back to this pubkey.
    func verifyDeclaredNip05(
        _ declared: String?,
        transport: Nip05Resolver.Transport = Nip05Resolver.pinnedTransport
    ) async {
        guard let hex,
              let declared = ContentSanitizer.profileAddress(declared),
              attemptedNip05Verification != declared
        else { return }
        attemptedNip05Verification = declared
        if await Nip05Resolver.verifies(
            declaredAddress: declared,
            accountIdHex: hex,
            transport: transport
        ) {
            verifiedNip05 = declared
        }
    }

    func message(npub: String, using appState: AppState, onOpen: (String) -> Void) async {
        guard let hex else { return }
        startPrompt = nil
        let memberRef = ProfileReferenceResolution.referenceForResolution(npub) ?? hex
        await runStart(
            accountIdHex: hex,
            memberRef: memberRef,
            existingGroupIdHex: existingDirectChatGroupIdHex(accountIdHex: hex),
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
}
