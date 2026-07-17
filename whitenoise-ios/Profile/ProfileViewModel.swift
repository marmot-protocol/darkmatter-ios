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
    private(set) var addableGroups: [SharedGroupsProjection.SharedGroup] = []
    private(set) var verifiedNip05: String?

    let starter = DirectChatStarter()
    let directory = RecipientDirectory()
    private var attemptedNip05Verification: String?
    private var resolutionGeneration: UInt64 = 0

    func resolve(npub: String, using appState: AppState) async {
        resolutionGeneration &+= 1
        let generation = resolutionGeneration
        // A reused profile surface must fail closed while the new identity is
        // resolving. Keeping the previous account visible through a failed
        // client lookup would also keep its trust and shared-group state.
        applyResolvedAccount(nil)
        startPrompt = nil
        sharedGroups = []
        addableGroups = []
        guard let reference = ProfileReferenceResolution.referenceForResolution(npub) else {
            return
        }
        guard let client = try? appState.currentMarmotClient() else { return }
        let resolvedHex = await client.accountIdHex(reference: reference)
        guard !Task.isCancelled, generation == resolutionGeneration else { return }
        applyResolvedAccount(resolvedHex)
        guard let resolvedHex else { return }
        // Trigger enrichment (cached read + background relay fetch).
        _ = appState.profile(forAccountIdHex: resolvedHex)
        await directory.load(using: appState, force: true)
        guard !Task.isCancelled,
              generation == resolutionGeneration,
              hex == resolvedHex
        else { return }
        sharedGroups = SharedGroupsProjection.sharedGroups(
            snapshots: directory.snapshots,
            targetAccountIdHex: resolvedHex,
            myAccountIdHex: appState.activeAccount?.accountIdHex
        )
        addableGroups = SharedGroupsProjection.addableGroups(
            snapshots: directory.snapshots,
            targetAccountIdHex: resolvedHex,
            myAccountIdHex: appState.activeAccount?.accountIdHex
        )
    }

    /// The verified badge is earned per pubkey. A reused profile surface
    /// resolving to a different account must shed it — retaining it would
    /// paint another pubkey's verification, a fail-open trust signal.
    func applyResolvedAccount(_ resolvedHex: String?) {
        if hex != resolvedHex {
            verifiedNip05 = nil
            attemptedNip05Verification = nil
            startPrompt = nil
        }
        hex = resolvedHex
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
        let verifyingHex = hex
        attemptedNip05Verification = declared
        let verified = await Nip05Resolver.verifies(
            declaredAddress: declared,
            accountIdHex: verifyingHex,
            transport: transport
        )
        // The profile can change while the network lookup is suspended. Only
        // the identity and declaration that started this request may receive
        // its result.
        guard !Task.isCancelled,
              hex == verifyingHex,
              attemptedNip05Verification == declared
        else { return }
        verifiedNip05 = verified ? declared : nil
    }

    func message(npub: String, using appState: AppState, onOpen: (String) -> Void) async {
        guard let hex else { return }
        startPrompt = nil
        // The reuse decision needs the directory; join any in-flight load so
        // a fast tap can't create a duplicate direct chat.
        await directory.load(using: appState, force: true)
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
