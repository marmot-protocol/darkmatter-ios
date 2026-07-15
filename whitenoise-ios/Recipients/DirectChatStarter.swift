import Foundation
import MarmotKit

/// Failure taxonomy for starting a direct chat. On this path a recipient
/// whose identity resolves but who has no usable messaging setup gets an
/// invite prompt, not an error: `MissingKeyPackage`, `InvalidKeyPackageEvent`,
/// and post-resolution `InvalidIdentity` all mean "not reachable on White
/// Noise yet". Group-membership mutations keep their strict error mapping.
nonisolated enum StartChatFailurePresentation {
    enum Failure: Equatable {
        case missingSetup
        case other(message: String)
    }

    static func failure(for error: Error) -> Failure {
        guard let marmotError = error as? MarmotKitError else {
            return .other(message: error.localizedDescription)
        }
        switch marmotError {
        case .MissingKeyPackage, .InvalidKeyPackageEvent, .InvalidIdentity:
            return .missingSetup
        default:
            return .other(message: marmotError.localizedDescription)
        }
    }

    static func inviteDetail(recipientName: String?) -> String {
        if let recipientName, !recipientName.isEmpty {
            return L10n.formatted(
                "%@ isn't on White Noise yet. Share the app so you can chat securely.",
                recipientName
            )
        }
        return L10n.string("They aren't on White Noise yet. Share the app so you can chat securely.")
    }

    static func inviteMessage() -> String {
        L10n.string("Let's chat on White Noise — private, secure messaging. Get it at https://whitenoise.chat and share your profile QR with me.")
    }
}

/// Starts (or reopens) a direct chat with one person. Owns the flow-level
/// in-flight guard so a fast double-tap — on the same row or a different one —
/// can't create two groups, and reports a row-scoped identity so only the
/// tapped person's row shows progress.
@MainActor
@Observable
final class DirectChatStarter {
    enum Outcome: Equatable {
        case opened(groupIdHex: String)
        case created(groupIdHex: String)
        case failed(StartChatFailurePresentation.Failure)
        /// Another start was already in flight; nothing happened.
        case ignored
    }

    /// Account id of the person whose start is in flight, for row-scoped
    /// progress. `nil` when idle.
    private(set) var creatingAccountIdHex: String?

    var isCreating: Bool { creatingAccountIdHex != nil }

    /// Opens `existingGroupIdHex` when the person already shares an open
    /// direct chat; otherwise creates an unnamed two-member group. The guard
    /// is taken synchronously before the first await.
    func start(
        accountIdHex: String,
        memberRef: String,
        existingGroupIdHex: String?,
        using appState: AppState
    ) async -> Outcome {
        guard creatingAccountIdHex == nil else { return .ignored }
        guard let accountRef = appState.activeAccountRef else {
            return .failed(.other(message: L10n.string("No active account is selected.")))
        }
        if let existingGroupIdHex {
            return .opened(groupIdHex: existingGroupIdHex)
        }
        creatingAccountIdHex = accountIdHex
        defer { creatingAccountIdHex = nil }
        do {
            let client = try appState.currentMarmotClient()
            let groupIdHex = try await client.createGroup(
                accountRef: accountRef,
                name: "",
                memberRefs: [memberRef],
                description: nil
            )
            return .created(groupIdHex: groupIdHex)
        } catch {
            return .failed(StartChatFailurePresentation.failure(for: error))
        }
    }
}
