import Foundation
import Observation
import MarmotKit

/// Owns the live state of a single conversation: the merged timeline of
/// message bubbles + system events, aggregated reactions, the group roster,
/// the in-progress reply, and the send pipeline.
@Observable
final class ConversationViewModel {

    /// One emoji's tally on a target message.
    struct ReactionTally: Identifiable, Hashable {
        let emoji: String
        let count: Int
        let mine: Bool
        var id: String { emoji }
    }

    private(set) var timeline: [TimelineItem] = []
    private(set) var group: AppGroupRecordFfi
    private(set) var members: [AppGroupMemberRecordFfi] = []
    /// targetMessageId → emoji tallies, derived from reaction messages.
    private(set) var reactions: [String: [ReactionTally]] = [:]
    /// Message ids tombstoned by a delete payload (rendered as a placeholder).
    private(set) var deletedMessageIds: Set<String> = []
    private(set) var isLoading = false
    private(set) var sendInFlight = false
    private(set) var error: String?

    /// The message the composer is currently replying to (set by swipe / menu).
    var replyingTo: AppMessageRecordFfi?

    private weak var appState: AppState?
    private var messagesTask: Task<Void, Never>?
    private var groupStateTask: Task<Void, Never>?

    /// All messages we've seen by id, for reply-target lookups.
    private var messageById: [String: AppMessageRecordFfi] = [:]
    /// Reaction messages by their own id (incl. optimistic), re-aggregated on change.
    private var reactionRecords: [String: AppMessageRecordFfi] = [:]
    /// Live agent-stream watch tasks, keyed by stream id.
    private var streamWatchTasks: [String: Task<Void, Never>] = [:]
    /// Accumulated text per live stream, keyed by stream id.
    private var streamText: [String: String] = [:]

    /// Agent-stream control envelopes are never chat bubbles.
    private static let agentStreamMarker = "marmot.agent_text_stream.v1"

    var myAccountId: String? { appState?.activeAccount?.accountIdHex }

    /// The other participant's account id (pubkey hex) in a 1:1 chat: the first
    /// member that isn't us. `memberIdHex` is the pubkey hex (same space as
    /// `accountIdHex`); `member.account` is a local-only label, not comparable.
    var otherMember: String? {
        GroupDisplay.otherMemberAccount(in: members, myAccountId: myAccountId)
    }

    var displayTitle: String {
        guard let appState else {
            if let name = ProfileSanitizer.groupName(group.name) { return name }
            return IdentityFormatter.short(group.groupIdHex)
        }
        return GroupDisplay.title(
            group: group,
            otherMember: otherMember,
            memberCount: members.count,
            appState: appState
        )
    }

    var displaySubtitle: String {
        let memberCount = members.count
        if memberCount == 0 { return "Just you" }
        let suffix = memberCount == 1 ? "member" : "members"
        return "\(memberCount) \(suffix)"
    }

    var isSelfAdmin: Bool {
        guard let me = myAccountId else { return false }
        return group.admins.contains(me)
    }

    var isLastAdmin: Bool {
        isSelfAdmin && group.admins.count <= 1
    }

    func isAdmin(_ member: AppGroupMemberRecordFfi) -> Bool {
        if group.admins.contains(member.memberIdHex) { return true }
        if let account = member.account { return group.admins.contains(account) }
        return false
    }

    /// Reaction tallies for a target message (empty when none).
    func reactions(for messageIdHex: String) -> [ReactionTally] {
        reactions[messageIdHex] ?? []
    }

    /// The quoted preview (sender name + text) for a reply bubble, if resolvable.
    func replyPreview(for record: AppMessageRecordFfi) -> (name: String, text: String)? {
        guard case .reply(let targetId, _)? = record.appMessage else { return nil }
        guard let target = messageById[targetId] else { return nil }
        let name = appState?.displayName(forAccountIdHex: target.sender) ?? "Unknown"
        let text = ProfileSanitizer.singleLine(displayBody(of: target), maxLength: 120) ?? ""
        return (name, text)
    }

    /// The visible body for a message — reply text for replies, else plaintext.
    func displayBody(of record: AppMessageRecordFfi) -> String {
        if case .reply(_, let text)? = record.appMessage { return text }
        return record.plaintext
    }

    init(appState: AppState, group: AppGroupRecordFfi) {
        self.appState = appState
        self.group = group
    }

    deinit {
        messagesTask?.cancel()
        groupStateTask?.cancel()
        for task in streamWatchTasks.values { task.cancel() }
    }

    func start() async {
        guard let appState, let accountRef = appState.activeAccountRef else { return }
        isLoading = true
        defer { isLoading = false }

        do {
            let messagesSub = try await appState.marmot.subscribeMessages(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex
            )
            for record in messagesSub.snapshot() { ingest(record) }

            let groupSub = try await appState.marmot.subscribeGroupState(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex
            )
            if let initial = groupSub.snapshot() {
                group = initial
            }

            members = try await appState.marmot.groupMembers(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex
            )

            messagesTask = Task { [weak self] in
                for await update in SubscriptionDriver.messages(messagesSub) {
                    await self?.fold(update)
                }
            }

            groupStateTask = Task { [weak self] in
                for await record in SubscriptionDriver.groupState(groupSub) {
                    await self?.applyGroupUpdate(record)
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Ingestion

    private func fold(_ update: MessageUpdateFfi) {
        switch update {
        case .message(let m):
            ingest(receivedToRecord(m))
        case .agentStreamStarted(let m):
            // Open a live bubble and watch the QUIC stream as it fills in.
            let sender = m.message.sender
            let streamIdHex = Self.agentStreamId(from: m.message.plaintext)
            Task { [weak self] in await self?.startWatching(sender: sender, streamIdHex: streamIdHex) }
        case .agentStreamFinalized:
            // The watch's .finished update swaps in the final text.
            break
        }
    }

    /// Route a message record to the timeline or the reactions index.
    private func ingest(_ record: AppMessageRecordFfi) {
        // Agent-stream control envelopes (Start/Final) aren't chat bubbles.
        if record.plaintext.contains(Self.agentStreamMarker) { return }
        if !record.messageIdHex.isEmpty {
            messageById[record.messageIdHex] = record
        }
        switch record.appMessage {
        case .reaction?:
            reactionRecords[reactionKey(record)] = record
            recomputeReactions()
        case .delete?:
            if case .delete(let target)? = record.appMessage {
                deletedMessageIds.insert(target)
            }
        case .retry?:
            break // internal, not rendered
        default:
            upsertBubble(record) // reply, media, or plain text
        }
    }

    func isDeleted(_ messageIdHex: String) -> Bool {
        deletedMessageIds.contains(messageIdHex)
    }

    private func upsertBubble(_ record: AppMessageRecordFfi) {
        if !record.messageIdHex.isEmpty,
           let idx = timeline.firstIndex(where: { item in
               if case .message(let existing, _) = item.kind {
                   return existing.messageIdHex == record.messageIdHex
               }
               return false
           }) {
            timeline[idx] = .message(record)
        } else {
            timeline.append(.message(record))
        }
        timeline.sort { $0.timestamp < $1.timestamp }
    }

    private func reactionKey(_ record: AppMessageRecordFfi) -> String {
        record.messageIdHex.isEmpty ? UUID().uuidString : record.messageIdHex
    }

    /// Rebuild the per-target reaction tallies from all reaction messages,
    /// processed oldest-first so adds/removes net out per (sender, emoji).
    private func recomputeReactions() {
        let me = myAccountId ?? ""
        let ordered: [AppMessageRecordFfi] = reactionRecords.values
            .sorted { $0.recordedAt < $1.recordedAt }

        var byTarget: [String: [String: Set<String>]] = [:] // target -> emoji -> senders
        for record in ordered {
            guard case .reaction(let target, let emoji, let removed)? = record.appMessage else { continue }
            var emojis: [String: Set<String>] = byTarget[target] ?? [:]
            if removed {
                for key in emojis.keys {
                    emojis[key]?.remove(record.sender)
                }
            } else if !emoji.isEmpty {
                var senders: Set<String> = emojis[emoji] ?? []
                senders.insert(record.sender)
                emojis[emoji] = senders
            }
            byTarget[target] = emojis
        }

        var result: [String: [ReactionTally]] = [:]
        for (target, emojis) in byTarget {
            var tallies: [ReactionTally] = []
            for (emoji, senders) in emojis where !senders.isEmpty {
                tallies.append(ReactionTally(emoji: emoji, count: senders.count, mine: senders.contains(me)))
            }
            guard !tallies.isEmpty else { continue }
            tallies.sort { lhs, rhs in
                lhs.count == rhs.count ? lhs.emoji < rhs.emoji : lhs.count > rhs.count
            }
            result[target] = tallies
        }
        reactions = result
    }

    private func receivedToRecord(_ r: RuntimeMessageReceivedFfi) -> AppMessageRecordFfi {
        AppMessageRecordFfi(
            messageIdHex: r.message.messageIdHex,
            direction: "received",
            groupIdHex: r.message.groupIdHex,
            sender: r.message.sender,
            plaintext: r.message.plaintext,
            appMessage: r.message.appMessage,
            recordedAt: UInt64(Date().timeIntervalSince1970),
            receivedAt: UInt64(Date().timeIntervalSince1970)
        )
    }

    private func applyGroupUpdate(_ record: AppGroupRecordFfi) async {
        let previousName = group.name
        let wasArchived = group.archived
        group = record

        if !previousName.isEmpty && previousName != record.name {
            appendSystemEvent(.groupRenamed(record.name))
        }
        if record.archived && !wasArchived {
            appendSystemEvent(.groupArchived)
        } else if !record.archived && wasArchived {
            appendSystemEvent(.groupUnarchived)
        }
        await refreshMembers()
    }

    private func appendSystemEvent(_ event: SystemEvent) {
        let now = UInt64(Date().timeIntervalSince1970)
        timeline.append(.systemEvent(id: UUID().uuidString, event: event, timestamp: now))
        timeline.sort { $0.timestamp < $1.timestamp }
    }

    private func refreshMembers() async {
        guard let appState, let accountRef = appState.activeAccountRef else { return }
        do {
            let next = try await appState.marmot.groupMembers(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex
            )
            if next.map(\.memberIdHex) != members.map(\.memberIdHex) {
                appendSystemEvent(.rosterChanged)
            }
            members = next
        } catch {
            // Silent; the next subscription tick will retry.
        }
    }

    // MARK: - Send

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let appState,
              let accountRef = appState.activeAccountRef else { return }

        let replyTargetId = replyTargetMessageId()
        let tempId = UUID().uuidString
        let now = UInt64(Date().timeIntervalSince1970)
        let optimisticPayload: AppMessagePayloadFfi? = replyTargetId.map {
            .reply(targetMessageId: $0, text: trimmed)
        }
        let optimistic = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "sent",
            groupIdHex: group.groupIdHex,
            sender: appState.activeAccount?.accountIdHex ?? "",
            plaintext: trimmed,
            appMessage: optimisticPayload,
            recordedAt: now,
            receivedAt: now
        )
        timeline.append(.pendingMessage(tempId: tempId, record: optimistic))
        timeline.sort { $0.timestamp < $1.timestamp }
        replyingTo = nil

        sendInFlight = true
        defer { sendInFlight = false }
        do {
            let summary: SendSummaryFfi
            if let replyTargetId {
                summary = try await appState.marmot.replyToMessage(
                    accountRef: accountRef,
                    groupIdHex: group.groupIdHex,
                    targetMessageId: replyTargetId,
                    text: trimmed
                )
            } else {
                summary = try await appState.marmot.sendText(
                    accountRef: accountRef,
                    groupIdHex: group.groupIdHex,
                    text: trimmed
                )
            }
            confirmSent(tempId: tempId, record: optimistic, messageId: summary.messageIds.first)
        } catch {
            markFailed(tempId: tempId)
            self.error = error.localizedDescription
            await MainActor.run {
                Haptics.error()
                appState.present(.error("Send failed", message: error.localizedDescription))
            }
        }
    }

    private func replyTargetMessageId() -> String? {
        guard let replyingTo, !replyingTo.messageIdHex.isEmpty else { return nil }
        return replyingTo.messageIdHex
    }

    private func confirmSent(tempId: String, record: AppMessageRecordFfi, messageId: String?) {
        let realId = messageId ?? ""
        let confirmed = AppMessageRecordFfi(
            messageIdHex: realId,
            direction: "sent",
            groupIdHex: record.groupIdHex,
            sender: record.sender,
            plaintext: record.plaintext,
            appMessage: record.appMessage,
            recordedAt: record.recordedAt,
            receivedAt: record.receivedAt
        )
        if !realId.isEmpty { messageById[realId] = confirmed }
        let rowId = "msg:\(realId.isEmpty ? tempId : realId)"
        if let idx = timeline.firstIndex(where: { $0.id == "msg:\(tempId)" }) {
            timeline[idx] = TimelineItem(
                id: rowId,
                kind: .message(record: confirmed, status: .sent),
                timestamp: confirmed.recordedAt
            )
        }
    }

    private func markFailed(tempId: String) {
        guard let idx = timeline.firstIndex(where: { $0.id == "msg:\(tempId)" }),
              case .message(let record, _) = timeline[idx].kind else { return }
        timeline[idx] = TimelineItem(
            id: "msg:\(tempId)",
            kind: .message(record: record, status: .failed),
            timestamp: record.recordedAt
        )
    }

    // MARK: - Reactions

    /// Tombstone our own message. Optimistically marks it deleted, then
    /// publishes the delete payload (reverting on failure).
    func deleteMessage(_ message: AppMessageRecordFfi) async {
        guard let appState, let accountRef = appState.activeAccountRef,
              !message.messageIdHex.isEmpty else { return }
        deletedMessageIds.insert(message.messageIdHex)
        do {
            _ = try await appState.marmot.deleteMessage(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex,
                targetMessageId: message.messageIdHex
            )
            Haptics.warning()
        } catch {
            deletedMessageIds.remove(message.messageIdHex)
            Haptics.error()
            appState.present(.error("Couldn't delete message", message: error.localizedDescription))
        }
    }

    // MARK: - Agent text streaming

    struct AgentStreamEnvelope: Decodable {
        let marmotPayload: String
        let streamId: String?

        enum CodingKeys: String, CodingKey {
            case marmotPayload = "marmot_payload"
            case streamId = "stream_id"
        }
    }

    static func agentStreamId(from plaintext: String) -> String? {
        guard let data = plaintext.data(using: .utf8),
              let envelope = try? JSONDecoder().decode(AgentStreamEnvelope.self, from: data),
              envelope.marmotPayload == agentStreamMarker,
              let streamId = envelope.streamId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !streamId.isEmpty,
              streamId.range(of: #"^[0-9a-fA-F]+$"#, options: .regularExpression) != nil
        else { return nil }
        return streamId.lowercased()
    }

    /// Watch a concrete live agent stream when the start payload names one;
    /// otherwise fall back to the latest live stream in this group.
    private func startWatching(sender: String, streamIdHex: String?) async {
        guard let appState, let accountRef = appState.activeAccountRef else { return }
        if let streamIdHex, streamWatchTasks[streamIdHex] != nil { return }
        do {
            let subscription = try await appState.marmot.watchAgentTextStream(
                accountRef: accountRef,
                groupIdHex: group.groupIdHex,
                streamIdHex: streamIdHex,
                serverCertDer: nil,
                // Developer mode points at a loopback broker (insecure); release
                // builds use the platform TLS verifier against a real cert.
                insecureLocal: appState.developerMode
            )
            let streamId = subscription.streamIdHex()
            if streamWatchTasks[streamId] != nil { return }
            streamText[streamId] = ""
            upsertStreamBubble(streamId: streamId, sender: sender, status: .streaming)
            let task = Task { [weak self] in
                while !Task.isCancelled, let update = await subscription.next() {
                    await self?.applyStreamUpdate(streamId: streamId, sender: sender, update: update)
                }
            }
            streamWatchTasks[streamId] = task
        } catch {
            // No resolvable start payload yet, or the broker is unreachable.
        }
    }

    private func applyStreamUpdate(streamId: String, sender: String, update: AgentStreamUpdateFfi) {
        switch update {
        case .chunk(_, let text):
            streamText[streamId, default: ""].append(text)
            upsertStreamBubble(streamId: streamId, sender: sender, status: .streaming)
        case .finished(let text, _, _):
            streamText[streamId] = text
            upsertStreamBubble(streamId: streamId, sender: sender, status: .received)
            streamWatchTasks[streamId] = nil
        case .failed:
            // Keep whatever streamed; just stop the live indicator.
            upsertStreamBubble(streamId: streamId, sender: sender, status: .received)
            streamWatchTasks[streamId] = nil
        }
    }

    /// Create or update the synthetic bubble for a live stream (keyed by id).
    private func upsertStreamBubble(streamId: String, sender: String, status: MessageStatus) {
        let rowId = "msg:stream:\(streamId)"
        let now = UInt64(Date().timeIntervalSince1970)
        let record = AppMessageRecordFfi(
            messageIdHex: "",
            direction: "received",
            groupIdHex: group.groupIdHex,
            sender: sender,
            plaintext: streamText[streamId] ?? "",
            appMessage: nil,
            recordedAt: now,
            receivedAt: now
        )
        if let idx = timeline.firstIndex(where: { $0.id == rowId }) {
            let timestamp = timeline[idx].timestamp
            timeline[idx] = TimelineItem(
                id: rowId,
                kind: .message(record: record, status: status),
                timestamp: timestamp
            )
        } else {
            timeline.append(
                TimelineItem(id: rowId, kind: .message(record: record, status: status), timestamp: now)
            )
            timeline.sort { $0.timestamp < $1.timestamp }
        }
    }

    func toggleReaction(_ emoji: String, on message: AppMessageRecordFfi) async {
        guard let appState, let accountRef = appState.activeAccountRef,
              !message.messageIdHex.isEmpty else { return }
        let alreadyMine = reactions(for: message.messageIdHex).contains { $0.emoji == emoji && $0.mine }

        // Optimistic: synthesize a reaction record and re-aggregate.
        let me = appState.activeAccount?.accountIdHex ?? ""
        let synthetic = AppMessageRecordFfi(
            messageIdHex: "optimistic-\(UUID().uuidString)",
            direction: "sent",
            groupIdHex: group.groupIdHex,
            sender: me,
            plaintext: "",
            appMessage: .reaction(targetMessageId: message.messageIdHex, emoji: alreadyMine ? "" : emoji, removed: alreadyMine),
            recordedAt: UInt64(Date().timeIntervalSince1970),
            receivedAt: UInt64(Date().timeIntervalSince1970)
        )
        reactionRecords[synthetic.messageIdHex] = synthetic
        recomputeReactions()
        Haptics.tap()

        do {
            if alreadyMine {
                _ = try await appState.marmot.unreactFromMessage(
                    accountRef: accountRef,
                    groupIdHex: group.groupIdHex,
                    targetMessageId: message.messageIdHex
                )
            } else {
                _ = try await appState.marmot.reactToMessage(
                    accountRef: accountRef,
                    groupIdHex: group.groupIdHex,
                    targetMessageId: message.messageIdHex,
                    emoji: emoji
                )
            }
        } catch {
            // Revert the optimistic change.
            reactionRecords.removeValue(forKey: synthetic.messageIdHex)
            recomputeReactions()
            Haptics.error()
            appState.present(.error("Reaction failed", message: error.localizedDescription))
        }
    }
}
