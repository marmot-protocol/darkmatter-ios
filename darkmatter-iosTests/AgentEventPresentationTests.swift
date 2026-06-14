import Foundation
import Testing
@testable import darkmatter_ios
@testable import MarmotKit

struct AgentEventPresentationTests {
    @Test func activityDisplayUsesJsonTextAndStatusTag() {
        let record = agentRecord(
            kind: MessageSemantics.kindAgentActivity,
            plaintext: #"{"v":1,"status":"thinking","text":"Thinking"}"#,
            tags: [MessageTagFfi(values: ["status", "thinking"])]
        )

        let display = AgentEventPresentation.display(for: record)

        #expect(display?.kind == .activity)
        #expect(display?.primaryText == "Thinking")
        #expect(display?.iconName == "ellipsis.message")
    }

    @Test func operationDisplayPrefersTextAndFallsBackToPreview() {
        let record = agentRecord(
            kind: MessageSemantics.kindAgentOperation,
            plaintext: #"{"v":1,"event_type":"tool_call","status":"started","name":"delegate_task","preview":"Search for and summarize the latest b...","text":"🔀 delegate_task: \"Search...\""}"#,
            tags: [
                MessageTagFfi(values: ["operation", "tool_call"]),
                MessageTagFfi(values: ["operation-status", "started"]),
                MessageTagFfi(values: ["operation-name", "delegate_task"]),
            ]
        )

        let display = AgentEventPresentation.display(for: record)

        #expect(display?.kind == .operation)
        #expect(display?.primaryText == "🔀 delegate_task: \"Search...\"")
        #expect(display?.secondaryText == "delegate task")
        #expect(display?.iconName == "wrench.and.screwdriver")
    }

    @Test func previewTextFallsBackToPreviewWhenTextMissing() {
        let text = AgentEventPresentation.previewText(
            from: #"{"v":1,"preview":"Search for and summarize the latest b..."}"#
        )
        #expect(text == "Search for and summarize the latest b...")
    }

    @MainActor
    @Test func agentOperationTimelineRowIsVisibleWithoutStreamingDebug() throws {
        let viewModel = ConversationViewModel(
            appState: AppState(client: try MarmotClient.testClient()),
            group: testAgentGroup()
        )
        let operation = timelineRecord(
            messageIdHex: hex("aa"),
            sender: hex("11"),
            plaintext: #"{"v":1,"event_type":"tool_call","status":"started","text":"Searching"}"#,
            kind: MessageSemantics.kindAgentOperation,
            tags: [MessageTagFfi(values: ["operation", "tool_call"])],
            timelineAt: 1
        )

        viewModel.applyTimelinePage(
            TimelinePageFfi(messages: [operation], hasMoreBefore: false, hasMoreAfter: false),
            placement: .window
        )

        #expect(viewModel.timeline.count == 1)
        guard case .message(let record, _) = viewModel.timeline.first?.kind else {
            Issue.record("Expected an agent operation message row")
            return
        }
        #expect(record.kind == MessageSemantics.kindAgentOperation)
    }
}

private func agentRecord(
    kind: UInt64,
    plaintext: String,
    tags: [MessageTagFfi]
) -> AppMessageRecordFfi {
    AppMessageRecordFfi(
        messageIdHex: hex("aa"),
        direction: "received",
        groupIdHex: hex("bb"),
        sender: hex("11"),
        plaintext: plaintext,
        contentTokens: MarkdownDocumentFfi.emptyDocument,
        kind: kind,
        tags: tags,
        recordedAt: 1,
        receivedAt: 1
    )
}

private func timelineRecord(
    messageIdHex: String,
    sender: String,
    plaintext: String,
    kind: UInt64,
    tags: [MessageTagFfi],
    timelineAt: UInt64
) -> TimelineMessageRecordFfi {
    TimelineMessageRecordFfi(
        messageIdHex: messageIdHex,
        sourceMessageIdHex: nil,
        direction: "received",
        groupIdHex: hex("bb"),
        sender: sender,
        plaintext: plaintext,
        contentTokens: MarkdownDocumentFfi.emptyDocument,
        kind: kind,
        tags: tags,
        timelineAt: timelineAt,
        receivedAt: timelineAt,
        replyToMessageIdHex: nil,
        replyPreview: nil,
        mediaJson: nil,
        agentTextStreamJson: nil,
        reactions: TimelineReactionSummaryFfi(byEmoji: [], userReactions: []),
        deleted: false,
        deletedByMessageIdHex: nil,
        invalidationStatus: nil
    )
}

private func testAgentGroup() -> AppGroupRecordFfi {
    AppGroupRecordFfi(
        groupIdHex: hex("bb"),
        endpoint: "",
        name: "Hermes",
        description: "",
        admins: [],
        relays: [],
        nostrGroupIdHex: "",
        avatarUrl: nil,
        avatarDim: nil,
        avatarThumbhash: nil,
        encryptedMedia: AppGroupEncryptedMediaComponentFfi(
            componentId: 0x8008,
            component: "marmot.group.encrypted-media.v1",
            required: true,
            mediaFormat: MessageSemantics.encryptedMediaVersion,
            allowedLocatorKinds: ["blossom-v1"],
            defaultBlobEndpoints: [
                AppBlobEndpointFfi(locatorKind: "blossom-v1", baseUrl: "https://blossom.primal.net")
            ]
        ),
        archived: false,
        pendingConfirmation: false,
        welcomerAccountIdHex: nil,
        viaWelcomeMessageIdHex: nil
    )
}

private func hex(_ byte: String) -> String {
    String(repeating: byte, count: 32)
}
