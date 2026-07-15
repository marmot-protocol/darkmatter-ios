import Foundation
import MarmotKit

/// Screen-lifetime directory of people derivable from the active account's
/// chat state. Loads the durable chat-list rows plus each group's roster off
/// the MainActor, then projects candidates ordered by recent conversation
/// activity. Rebuilt per screen presentation — Marmot stays the source of
/// truth and nothing here is persisted.
@MainActor
@Observable
final class RecipientDirectory {
    private(set) var snapshots: [RecipientGroupSnapshot] = []
    private(set) var candidates: [RecipientCandidate] = []
    private(set) var isLoading = false
    private(set) var loadError: String?
    private var loadedAccountRef: String?

    private static let profileWarmupLimit = 24

    func load(using appState: AppState, force: Bool = false) async {
        guard let accountRef = appState.activeAccountRef else {
            snapshots = []
            candidates = []
            loadedAccountRef = nil
            return
        }
        if loadedAccountRef == accountRef, !force, !snapshots.isEmpty { return }
        guard !isLoading else { return }
        isLoading = true
        loadError = nil
        defer { isLoading = false }
        do {
            let client = try appState.currentMarmotClient()
            let myAccountIdHex = appState.activeAccount?.accountIdHex
            let loaded = try await Self.loadSnapshots(client: client, accountRef: accountRef)
            let derived = await Self.deriveCandidates(from: loaded, myAccountIdHex: myAccountIdHex)
            try Task.checkCancellation()
            guard appState.activeAccountRef == accountRef else { return }
            snapshots = loaded
            candidates = derived
            loadedAccountRef = accountRef
            for candidate in derived.prefix(Self.profileWarmupLimit) {
                _ = appState.profile(forAccountIdHex: candidate.accountIdHex)
            }
        } catch is CancellationError {
            return
        } catch {
            guard appState.activeAccountRef == accountRef else { return }
            loadError = error.localizedDescription
        }
    }

    /// Search fields resolved at match time so nickname/profile updates that
    /// land mid-screen are reflected without rebuilding the directory.
    static func matchFields(
        for candidate: RecipientCandidate,
        appState: AppState
    ) -> RecipientSearch.MatchFields {
        RecipientSearch.MatchFields(
            displayName: appState.knownDisplayName(forAccountIdHex: candidate.accountIdHex),
            nickname: appState.contactNickname(forAccountIdHex: candidate.accountIdHex),
            nip05: ContentSanitizer.profileAddress(
                appState.profile(forAccountIdHex: candidate.accountIdHex)?.nip05
            )
        )
    }

    /// Rosters load per row; a row whose details read fails still contributes
    /// its last-message sender, so one bad group can't blank the directory.
    private nonisolated static func loadSnapshots(
        client: MarmotClient,
        accountRef: String
    ) async throws -> [RecipientGroupSnapshot] {
        let rows = try await client.chatList(accountRef: accountRef, includeArchived: true)
        var snapshots: [RecipientGroupSnapshot] = []
        snapshots.reserveCapacity(rows.count)
        for row in rows {
            try Task.checkCancellation()
            let details = try? await client.groupDetails(
                accountRef: accountRef,
                groupIdHex: row.groupIdHex
            )
            snapshots.append(RecipientGroupSnapshot(row: row, details: details))
        }
        return snapshots
    }

    private nonisolated static func deriveCandidates(
        from snapshots: [RecipientGroupSnapshot],
        myAccountIdHex: String?
    ) async -> [RecipientCandidate] {
        RecipientCandidateDerivation.candidates(from: snapshots, myAccountIdHex: myAccountIdHex)
    }
}
