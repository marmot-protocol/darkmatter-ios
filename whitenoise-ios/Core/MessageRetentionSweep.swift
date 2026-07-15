import Foundation
import MarmotKit

/// Pure decisions for the foreground expiration sweep: which accounts and
/// groups to visit and whether a pass may touch the runtime at all.
nonisolated enum MessageRetentionSweepPolicy {

    static let sweepIntervalNanoseconds: UInt64 = 30_000_000_000

    /// A pass needs a live foreground runtime with an active account; the
    /// local-foreground gate already folds scene, suspension, and client state.
    static func canSweep(
        phase: AppState.Phase,
        canUseRuntimeForLocalForegroundWork: Bool
    ) -> Bool {
        phase == .ready && canUseRuntimeForLocalForegroundWork
    }

    static func sweepAccountRefs(from accounts: [AccountSummaryFfi]) -> [String] {
        accounts.filter { !$0.signedOut }.map(\.label)
    }

    static func sweepGroupIds(from groups: [AppGroupRecordFfi]) -> [String] {
        var seen = Set<String>()
        return groups
            .filter { $0.disappearingMessageSecs > 0 && seen.insert($0.groupIdHex).inserted }
            .map(\.groupIdHex)
    }
}

nonisolated enum MessageRetentionSweep {
    struct Outcome {
        var prunedGroupIds: Set<String> = []
        var prunedMessageCount: UInt64 = 0
    }

    /// One sweep pass: for every retention-enabled group, secure-delete
    /// expired records and evict their decrypted media from the cache.
    /// Per-account/per-group failures are best-effort skips.
    static func run(client: MarmotClient, accountRefs: [String]) async -> Outcome {
        var outcome = Outcome()
        for accountRef in accountRefs {
            guard !Task.isCancelled else { break }
            guard let subscription = try? await client.subscribeChats(
                accountRef: accountRef,
                includeArchived: true
            ) else { continue }
            let groups = await client.chatsSubscriptionSnapshot(subscription)
            for groupIdHex in MessageRetentionSweepPolicy.sweepGroupIds(from: groups) {
                guard !Task.isCancelled else { break }
                // Snapshot references before the prune: the result reports
                // ciphertext hashes, but the cache is keyed by plaintext hash
                // and the records are gone once the engine deletes them. A
                // failed snapshot skips the group's prune entirely — deleting
                // without it would orphan decrypted cache files forever; the
                // next pass retries.
                guard let mediaRecords = try? await client.listMedia(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex
                ) else { continue }
                let references = mediaRecords.map(\.reference)
                guard let result = try? await client.secureDeleteExpired(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex
                ) else { continue }
                if !result.mediaCiphertextSha256.isEmpty {
                    await MessageMediaCache.removeCachedData(
                        forCiphertextHashes: Set(result.mediaCiphertextSha256.map { $0.lowercased() }),
                        in: references
                    )
                }
                if result.prunedMessages > 0 || !result.mediaCiphertextSha256.isEmpty {
                    outcome.prunedGroupIds.insert(groupIdHex)
                    outcome.prunedMessageCount &+= result.prunedMessages
                }
            }
        }
        return outcome
    }
}

/// Owns the foreground expiration-sweep loop: one pass on start (foreground
/// resume / ready maintenance), then periodic passes while the runtime stays
/// available. Cancelled alongside the other foreground maintenance when the
/// app suspends.
@MainActor
final class MessageRetentionSweeper {
    private var sweepTask: Task<Void, Never>?
    private weak var appState: AppState?

    deinit {
        sweepTask?.cancel()
    }

    /// Live only while an uncancelled sweep loop exists; `cancelWithoutAwaiting`
    /// leaves the task reference behind, so a bare nil-check would lie.
    var isSweeping: Bool { !(sweepTask?.isCancelled ?? true) }

    func start(appState: AppState) {
        self.appState = appState
        guard appState.phase == .ready else { return }
        let previousTask = sweepTask
        previousTask?.cancel()
        sweepTask = Task { [weak self] in
            // Drain the prior loop so two passes can never overlap.
            await previousTask?.value
            await self?.runSweepLoop()
        }
    }

    func cancelWithoutAwaiting() {
        sweepTask?.cancel()
    }

    func cancel() async {
        let task = sweepTask
        sweepTask = nil
        task?.cancel()
        await task?.value
    }

    private func runSweepLoop() async {
        while !Task.isCancelled {
            await sweepOnce()
            do {
                try await Task.sleep(nanoseconds: MessageRetentionSweepPolicy.sweepIntervalNanoseconds)
            } catch {
                return
            }
        }
    }

    private func sweepOnce() async {
        guard let appState,
              MessageRetentionSweepPolicy.canSweep(
                phase: appState.phase,
                canUseRuntimeForLocalForegroundWork: appState.canUseRuntimeForLocalForegroundWork
              ),
              let client = try? appState.currentMarmotClient()
        else { return }
        let accountRefs = MessageRetentionSweepPolicy.sweepAccountRefs(from: appState.accounts)
        guard !accountRefs.isEmpty else { return }
        let outcome = await MessageRetentionSweep.run(client: client, accountRefs: accountRefs)
        guard !Task.isCancelled, !outcome.prunedGroupIds.isEmpty else { return }
        appState.noteRetentionSweepCompleted(prunedGroupIds: outcome.prunedGroupIds)
    }
}
