import Foundation
import OSLog
import MarmotKit

/// Owns the conversation's read-marking pipeline: an optimistic "already marked"
/// set, a coalesced pending-flush queue (one debounced Marmot round-trip per
/// burst, #read-mark coalescing), and the bound-window pruning that keeps the
/// marked set from growing without limit. Extracted from `ConversationViewModel`;
/// the live conversation context (account/runtime, the loaded-window message ids,
/// and the chat-list-row callback) is injected so the async flush sees current
/// state, while the marked-set bookkeeping stays self-contained.
@MainActor
final class ConversationReadMarker {
    enum PendingFlushDecision: Equatable {
        case stop
        case retryWhenRuntimeReturns
        case flush
    }

    private static let performanceSignposter = OSSignposter(
        subsystem: "dev.ipf.whitenoise.ios",
        category: "Performance"
    )

    private static let readMarkCoalescingDelayNanoseconds: UInt64 = 100_000_000

    private let groupIdHex: String
    private let maxMarkedReadMessageIds: Int
    private weak var appState: AppState?
    /// The message ids currently in the loaded timeline window — used to bound
    /// the marked set to what can still be re-displayed. Evaluated lazily so the
    /// async flush prunes against the live window.
    private let loadedMessageIds: () -> Set<String>
    private let onChatListRowUpdated: ((ChatListRowFfi) -> Void)?

    private var markedReadMessageIds: Set<String> = []
    private var pendingReadMessageIds: [String] = []
    private var pendingReadMessageIdSet: Set<String> = []
    private var readMarkTask: Task<Void, Never>?
    private var readMarkTaskID: UUID?

    init(
        groupIdHex: String,
        maxMarkedReadMessageIds: Int,
        appState: AppState?,
        loadedMessageIds: @escaping () -> Set<String>,
        onChatListRowUpdated: ((ChatListRowFfi) -> Void)?
    ) {
        self.groupIdHex = groupIdHex
        self.maxMarkedReadMessageIds = maxMarkedReadMessageIds
        self.appState = appState
        self.loadedMessageIds = loadedMessageIds
        self.onChatListRowUpdated = onChatListRowUpdated
    }

    func markReadIfVisible(_ record: AppMessageRecordFfi, isDeleted: Bool) {
        guard Self.shouldMarkRead(
            record,
            isDeleted: isDeleted,
            alreadyMarked: markedReadMessageIds.contains(record.messageIdHex)
        ),
            let appState,
            let accountRef = appState.activeAccountRef
        else { return }

        markedReadMessageIds.insert(record.messageIdHex)
        enqueueReadMark(messageIdHex: record.messageIdHex, accountRef: accountRef)
        pruneMarkedReadMessageIds()
    }

    static func shouldMarkRead(_ record: AppMessageRecordFfi, isDeleted: Bool, alreadyMarked: Bool) -> Bool {
        !alreadyMarked
            && !isDeleted
            && !record.messageIdHex.isEmpty
            && record.kind == MessageSemantics.kindChat
    }

    nonisolated static func retainedMarkedReadMessageIds(
        _ current: Set<String>,
        loadedMessageIds: Set<String>,
        pendingMessageIds: Set<String>,
        limit: Int
    ) -> Set<String> {
        let pending = current.intersection(pendingMessageIds)
        let boundedLimit = max(0, limit)
        guard boundedLimit > 0 else { return pending }

        let loaded = current.intersection(loadedMessageIds)
        let retainedCandidates = loaded.union(pending)
        guard retainedCandidates.count > boundedLimit else {
            return retainedCandidates
        }

        var retained = pending
        let remainingCapacity = max(0, boundedLimit - retained.count)
        if remainingCapacity > 0 {
            for messageId in loaded.subtracting(retained).sorted().prefix(remainingCapacity) {
                retained.insert(messageId)
            }
        }
        return retained
    }

    func pruneMarkedReadMessageIds(force: Bool = false) {
        guard force || markedReadMessageIds.count > maxMarkedReadMessageIds else { return }
        markedReadMessageIds = Self.retainedMarkedReadMessageIds(
            markedReadMessageIds,
            loadedMessageIds: loadedMessageIds(),
            pendingMessageIds: pendingReadMessageIdSet,
            limit: maxMarkedReadMessageIds
        )
    }

    /// On re-receipt of a record the projection may have re-anchored it; drop it
    /// from the marked set (unless still pending flush) so it can be re-marked.
    func forgetMarkIfNotPending(_ messageIdHex: String) {
        if !pendingReadMessageIdSet.contains(messageIdHex) {
            markedReadMessageIds.remove(messageIdHex)
        }
    }

    private func enqueueReadMark(messageIdHex: String, accountRef: String) {
        guard pendingReadMessageIdSet.insert(messageIdHex).inserted else { return }
        pendingReadMessageIds.append(messageIdHex)
        scheduleReadMarkFlush(accountRef: accountRef)
    }

    private func scheduleReadMarkFlush(accountRef: String) {
        guard readMarkTask == nil else { return }
        let taskID = UUID()
        readMarkTaskID = taskID
        readMarkTask = Task { @MainActor [weak self] in
            defer {
                if self?.readMarkTaskID == taskID {
                    self?.readMarkTask = nil
                    self?.readMarkTaskID = nil
                }
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.readMarkCoalescingDelayNanoseconds)
                guard !Task.isCancelled else { return }
                guard await self?.flushPendingReadMarks(accountRef: accountRef) == true else { return }
            }
        }
    }

    private func flushPendingReadMarks(accountRef: String) async -> Bool {
        let appState = appState
        switch Self.pendingFlushDecision(
            hasPendingMessages: !pendingReadMessageIds.isEmpty,
            canUseRuntime: appState?.canUseRuntimeForForegroundWork == true,
            activeAccountMatches: appState?.activeAccountRef == accountRef
        ) {
        case .stop:
            pendingReadMessageIdSet = []
            pruneMarkedReadMessageIds(force: true)
            return false
        case .retryWhenRuntimeReturns:
            // Keep the task and queue alive while the app is backgrounded. The
            // task resumes its coalesced retry loop when the process/runtime is
            // available again, even if the viewport never emits another frame.
            return true
        case .flush:
            break
        }
        // Check availability BEFORE draining. If the runtime or account is
        // unavailable at flush time (e.g. the app backgrounded during the
        // coalescing window), leave the ids queued so the next flush retries —
        // draining first would drop the reads, and the weak re-arm only fires on
        // a viewport frame change that a same-rows foreground resume won't emit.
        guard let appState else { return false }

        let messageIds = pendingReadMessageIds
        pendingReadMessageIds = []
        let signpost = Self.performanceSignposter.beginInterval("ConversationReadMarker.flushPendingReadMarks")
        defer { Self.performanceSignposter.endInterval("ConversationReadMarker.flushPendingReadMarks", signpost) }

        defer {
            pendingReadMessageIdSet.subtract(messageIds)
            pruneMarkedReadMessageIds(force: true)
        }

        do {
            let client = try appState.currentMarmotClient()
            let results = await client.markTimelineMessagesRead(
                accountRef: accountRef,
                groupIdHex: groupIdHex,
                messageIdHexes: messageIds
            )
            for result in results where !result.succeeded {
                markedReadMessageIds.remove(result.messageIdHex)
            }
            if let row = results.compactMap(\.row).last {
                onChatListRowUpdated?(row)
            }
        } catch {
            markedReadMessageIds.subtract(messageIds)
        }

        return !pendingReadMessageIds.isEmpty && appState.activeAccountRef == accountRef
    }

    nonisolated static func pendingFlushDecision(
        hasPendingMessages: Bool,
        canUseRuntime: Bool,
        activeAccountMatches: Bool
    ) -> PendingFlushDecision {
        guard hasPendingMessages, activeAccountMatches else { return .stop }
        return canUseRuntime ? .flush : .retryWhenRuntimeReturns
    }

    func cancelPendingReadMarks() {
        readMarkTask?.cancel()
        readMarkTask = nil
        readMarkTaskID = nil
        if !pendingReadMessageIdSet.isEmpty {
            markedReadMessageIds.subtract(pendingReadMessageIdSet)
        }
        pendingReadMessageIds = []
        pendingReadMessageIdSet = []
        pruneMarkedReadMessageIds(force: true)
    }

    func clearMarks() {
        markedReadMessageIds.removeAll()
    }

#if DEBUG
    var markedReadMessageIdsForTesting: Set<String> { markedReadMessageIds }

    func insertMarkedReadMessageIdsForTesting(_ messageIds: Set<String>) {
        markedReadMessageIds.formUnion(messageIds)
        pruneMarkedReadMessageIds(force: true)
    }

    func insertPendingReadMessageIdsForTesting(_ messageIds: [String]) {
        for messageId in messageIds {
            guard pendingReadMessageIdSet.insert(messageId).inserted else { continue }
            pendingReadMessageIds.append(messageId)
        }
    }
#endif
}
