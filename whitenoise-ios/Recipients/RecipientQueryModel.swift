import Foundation
import MarmotKit

/// Search-field state for one recipient screen: the query text plus the
/// identifier-resolution state machine. Each screen (New Message, New Group,
/// Add Members) owns its own instance so queries don't leak between steps.
/// Marmot reference decoding and NIP-05 lookups run off the MainActor; NIP-05
/// lookups are debounced because each one is a network fetch.
@MainActor
@Observable
final class RecipientQueryModel {
    var text = ""
    private(set) var resolution: RecipientResolutionState = .idle

    private var resolveTask: Task<Void, Never>?
    private var resolveGeneration = 0

    static let nip05DebounceNanoseconds: UInt64 = 350_000_000

    var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isBlank: Bool { trimmedText.isEmpty }

    /// True when the query should skip the known-people browse and show the
    /// resolver row instead.
    var isIdentifierQuery: Bool {
        if case .none = RecipientIdentifierQuery.classify(text) { return false }
        return true
    }

    func clear() {
        resolveTask?.cancel()
        resolveGeneration += 1
        text = ""
        resolution = .idle
    }

    func queryChanged(using appState: AppState) {
        resolveTask?.cancel()
        resolveGeneration += 1
        let generation = resolveGeneration
        switch RecipientIdentifierQuery.classify(text) {
        case .none:
            resolution = .idle
        case .profileReference(let reference):
            resolution = .resolving
            resolveTask = Task { [weak self] in
                await self?.resolveProfileReference(
                    reference,
                    generation: generation,
                    using: appState
                )
            }
        case .nip05(let name, let domain):
            resolution = .resolving
            resolveTask = Task { [weak self] in
                await self?.resolveNip05(
                    name: name,
                    domain: domain,
                    generation: generation,
                    using: appState
                )
            }
        }
    }

    private func resolveProfileReference(
        _ reference: String,
        generation: Int,
        using appState: AppState
    ) async {
        guard let client = try? appState.currentMarmotClient() else {
            adopt(.failed, generation: generation)
            return
        }
        let accountIdHex = await client.accountIdHex(reference: reference)
        guard !Task.isCancelled else { return }
        guard let accountIdHex else {
            adopt(.invalid, generation: generation)
            return
        }
        warmProfile(accountIdHex, using: appState)
        adopt(
            .resolved(ResolvedRecipient(
                accountIdHex: accountIdHex,
                memberRef: reference,
                queriedNip05: nil
            )),
            generation: generation
        )
    }

    private func resolveNip05(
        name: String,
        domain: String,
        generation: Int,
        using appState: AppState
    ) async {
        try? await Task.sleep(nanoseconds: Self.nip05DebounceNanoseconds)
        guard !Task.isCancelled else { return }
        let result = await Nip05Resolver.resolve(name: name, domain: domain)
        guard !Task.isCancelled else { return }
        switch result {
        case .resolved(let accountIdHex):
            warmProfile(accountIdHex, using: appState)
            adopt(
                .resolved(ResolvedRecipient(
                    accountIdHex: accountIdHex,
                    memberRef: accountIdHex,
                    queriedNip05: "\(name)@\(domain)"
                )),
                generation: generation
            )
        case .noProfile:
            adopt(.noProfile, generation: generation)
        case .failed:
            adopt(.failed, generation: generation)
        case .invalidAddress:
            adopt(.invalid, generation: generation)
        }
    }

    private func adopt(_ state: RecipientResolutionState, generation: Int) {
        guard resolveGeneration == generation else { return }
        resolution = state
    }

    private func warmProfile(_ accountIdHex: String, using appState: AppState) {
        _ = appState.profile(forAccountIdHex: accountIdHex)
    }
}
