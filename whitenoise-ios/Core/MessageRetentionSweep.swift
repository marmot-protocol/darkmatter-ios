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
    static func run(
        client: MarmotClient,
        groupsByAccountRef: [String: [AppGroupRecordFfi]]
    ) async -> Outcome {
        var outcome = Outcome()
        for accountRef in groupsByAccountRef.keys.sorted() {
            guard !Task.isCancelled else { break }
            let groups = groupsByAccountRef[accountRef] ?? []
            for groupIdHex in MessageRetentionSweepPolicy.sweepGroupIds(from: groups) {
                guard !Task.isCancelled else { break }
                guard let result = try? await client.secureDeleteExpired(
                    accountRef: accountRef,
                    groupIdHex: groupIdHex
                ) else { continue }
                if !result.mediaPlaintextSha256.isEmpty {
                    await MessageMediaCache.removeCachedData(
                        forPlaintextHashes: Set(result.mediaPlaintextSha256)
                    )
                }
                if result.prunedMessages > 0
                    || !result.mediaCiphertextSha256.isEmpty
                    || !result.mediaPlaintextSha256.isEmpty
                {
                    outcome.prunedGroupIds.insert(groupIdHex)
                    outcome.prunedMessageCount &+= result.prunedMessages
                }
            }
        }
        return outcome
    }

    /// One-shot snapshot loading for background maintenance. The foreground
    /// sweeper retains its subscriptions separately across periodic passes.
    static func loadGroupSnapshots(
        client: MarmotClient,
        accountRefs: [String]
    ) async -> [String: [AppGroupRecordFfi]] {
        var groupsByAccountRef: [String: [AppGroupRecordFfi]] = [:]
        for accountRef in accountRefs {
            guard !Task.isCancelled else { break }
            guard let subscription = try? await client.subscribeChats(
                accountRef: accountRef,
                includeArchived: true
            ) else { continue }
            groupsByAccountRef[accountRef] = await client.chatsSubscriptionSnapshot(subscription)
        }
        return groupsByAccountRef
    }
}

/// Retains one live group subscription and folds its updates into the initial
/// one-shot snapshot. `ChatsSubscription.snapshot()` is consumed exactly once;
/// later sweep passes read this cache while the update task keeps it current.
@MainActor
private final class MessageRetentionGroupSubscription {
    private var groupsById: [String: AppGroupRecordFfi]
    private var updateTask: Task<Void, Never>?

    init(subscription: ChatsSubscription, initialGroups: [AppGroupRecordFfi]) {
        groupsById = Dictionary(
            initialGroups.map { ($0.groupIdHex, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        updateTask = Task { [weak self, subscription] in
            for await group in SubscriptionDriver.chats(subscription) {
                guard !Task.isCancelled else { return }
                self?.groupsById[group.groupIdHex] = group
            }
        }
    }

    deinit {
        updateTask?.cancel()
    }

    var groups: [AppGroupRecordFfi] {
        Array(groupsById.values)
    }

    func cancel() {
        updateTask?.cancel()
        updateTask = nil
    }
}

/// Owns the foreground expiration-sweep loop: one pass on start (foreground
/// resume / ready maintenance), then periodic passes while the runtime stays
/// available. Cancelled alongside the other foreground maintenance when the
/// app suspends.
@MainActor
final class MessageRetentionSweeper {
    private var sweepTask: Task<Void, Never>?
    private var groupSubscriptionsByAccountRef: [String: MessageRetentionGroupSubscription] = [:]
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
        cancelGroupSubscriptions()
        sweepTask = Task { [weak self] in
            // Drain the prior loop so two passes can never overlap.
            await previousTask?.value
            self?.cancelGroupSubscriptions()
            await self?.runSweepLoop()
        }
    }

    func cancelWithoutAwaiting() {
        sweepTask?.cancel()
        cancelGroupSubscriptions()
    }

    func cancel() async {
        let task = sweepTask
        sweepTask = nil
        task?.cancel()
        cancelGroupSubscriptions()
        await task?.value
        cancelGroupSubscriptions()
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
        let groupsByAccountRef = await groupSnapshots(client: client, accountRefs: accountRefs)
        let outcome = await MessageRetentionSweep.run(
            client: client,
            groupsByAccountRef: groupsByAccountRef
        )
        guard !Task.isCancelled, !outcome.prunedGroupIds.isEmpty else { return }
        appState.noteRetentionSweepCompleted(prunedGroupIds: outcome.prunedGroupIds)
    }

    private func groupSnapshots(
        client: MarmotClient,
        accountRefs: [String]
    ) async -> [String: [AppGroupRecordFfi]] {
        let currentAccounts = Set(accountRefs)
        let removedAccountRefs = groupSubscriptionsByAccountRef.keys.filter {
            !currentAccounts.contains($0)
        }
        for accountRef in removedAccountRefs {
            groupSubscriptionsByAccountRef.removeValue(forKey: accountRef)?.cancel()
        }

        var groupsByAccountRef: [String: [AppGroupRecordFfi]] = [:]
        for accountRef in accountRefs {
            guard !Task.isCancelled else { break }
            let state: MessageRetentionGroupSubscription
            if let existing = groupSubscriptionsByAccountRef[accountRef] {
                state = existing
            } else {
                guard let created = try? await client.subscribeChats(
                    accountRef: accountRef,
                    includeArchived: true
                ) else { continue }
                let initialGroups = await client.chatsSubscriptionSnapshot(created)
                guard !Task.isCancelled else { break }
                let createdState = MessageRetentionGroupSubscription(
                    subscription: created,
                    initialGroups: initialGroups
                )
                groupSubscriptionsByAccountRef[accountRef] = createdState
                state = createdState
            }
            groupsByAccountRef[accountRef] = state.groups
        }
        return groupsByAccountRef
    }

    private func cancelGroupSubscriptions() {
        for state in groupSubscriptionsByAccountRef.values {
            state.cancel()
        }
        groupSubscriptionsByAccountRef.removeAll()
    }
}

extension AppState {
    /// Runs one expiration pass from a BGAppRefresh launch. The runtime lease is
    /// always released, including cancellation and per-pass failure, so the
    /// shared store is closed again before iOS suspends the process.
    @MainActor
    func performBackgroundRetentionSweep() async -> Bool {
        if phase == .bootstrapping {
            await bootstrap()
        }
        // `.onboarding` also owns the runtime started by bootstrap. Acquiring
        // and releasing an empty lease in that state is intentional: on a cold
        // background launch it guarantees the shared SQLite store is closed
        // again even when no signed-in accounts remain to sweep.
        guard phaseOwnsLiveRuntime else { return true }

        var lease: NotificationActionRuntimeLease?
        do {
            let acquired = try await runtimeLifecycle.startRuntimeForNotificationAction()
            lease = acquired
            let accounts = try await acquired.client.listAccounts()
            let accountRefs = MessageRetentionSweepPolicy.sweepAccountRefs(from: accounts)
            let groupsByAccountRef = await MessageRetentionSweep.loadGroupSnapshots(
                client: acquired.client,
                accountRefs: accountRefs
            )
            let outcome = await MessageRetentionSweep.run(
                client: acquired.client,
                groupsByAccountRef: groupsByAccountRef
            )
            await runtimeLifecycle.suspendRuntimeAfterNotificationAction(acquired)
            lease = nil
            if !outcome.prunedGroupIds.isEmpty {
                noteRetentionSweepCompleted(prunedGroupIds: outcome.prunedGroupIds)
            }
            return !Task.isCancelled
        } catch {
            if let lease {
                await runtimeLifecycle.suspendRuntimeAfterNotificationAction(lease)
            }
            return false
        }
    }
}
