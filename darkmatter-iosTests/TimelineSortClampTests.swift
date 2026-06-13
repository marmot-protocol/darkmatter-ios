import Testing
@testable import darkmatter_ios
@testable import MarmotKit

/// #61 — the timeline sort key must be clamped to min(recordedAt, receivedAt) so
/// a future-dated message can't pin itself to the bottom of the conversation.
/// Display still uses the record's own recordedAt.
struct TimelineSortClampTests {
    private func record(
        messageIdHex: String = String(repeating: "a", count: 64),
        recordedAt: UInt64,
        receivedAt: UInt64
    ) -> AppMessageRecordFfi {
        AppMessageRecordFfi(
            messageIdHex: messageIdHex,
            direction: "received",
            groupIdHex: String(repeating: "c", count: 64),
            sender: String(repeating: "b", count: 64),
            plaintext: "hi",
            kind: MessageSemantics.kindChat,
            tags: [],
            recordedAt: recordedAt,
            receivedAt: receivedAt
        )
    }

    @Test func clampsFutureRecordedToReceived() {
        #expect(TimelineItem.sortTimestamp(for: record(recordedAt: 9_000_000, receivedAt: 1_000)) == 1_000)
    }

    @Test func usesRecordedWhenInThePast() {
        #expect(TimelineItem.sortTimestamp(for: record(recordedAt: 500, receivedAt: 1_000)) == 500)
    }

    @Test func fallsBackToRecordedWhenReceivedMissing() {
        #expect(TimelineItem.sortTimestamp(for: record(recordedAt: 500, receivedAt: 0)) == 500)
    }

    @Test func messageFactoryUsesClampedTimestamp() {
        #expect(TimelineItem.message(record(recordedAt: 9_000_000, receivedAt: 1_000)).timestamp == 1_000)
    }

    @Test func rowFrameKeyUsesStableRowIdentityForConfirmedMessages() {
        let message = TimelineItem.message(record(recordedAt: 500, receivedAt: 1_000))

        #expect(message.rowFrameKey == message.id)
        #expect(message.rowFrameKey == "msg:\(String(repeating: "a", count: 64))")
    }

    @Test func rowFrameKeyDoesNotCollapseEmptyMessageIdRows() {
        let emptyRecord = record(messageIdHex: "", recordedAt: 500, receivedAt: 1_000)
        let first = TimelineItem.pendingMessage(tempId: "pending-1", record: emptyRecord)
        let second = TimelineItem.pendingMessage(tempId: "pending-2", record: emptyRecord)

        #expect(first.rowFrameKey == "msg:pending-1")
        #expect(second.rowFrameKey == "msg:pending-2")
        #expect(first.rowFrameKey != second.rowFrameKey)
        #expect(!first.rowFrameKey.isEmpty)
        #expect(!second.rowFrameKey.isEmpty)
    }
}
