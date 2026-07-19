import Foundation
import Testing
@testable import whitenoise_ios

@MainActor
struct ConversationDraftStoreTests {
    @Test func draftsPersistAcrossStoreInstancesAndStayAccountGroupScoped() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let first = ConversationDraftStore(fileURL: fixture.file)
        await first.loadIfNeeded()
        first.setDraft("first account, first group", accountRef: "account-a", groupIdHex: "group-a")
        first.setDraft("first account, second group", accountRef: "account-a", groupIdHex: "group-b")
        first.setDraft("second account", accountRef: "account-b", groupIdHex: "group-a")
        await first.flush()

        let restored = ConversationDraftStore(fileURL: fixture.file)
        await restored.loadIfNeeded()

        #expect(restored.draft(accountRef: "account-a", groupIdHex: "group-a") == "first account, first group")
        #expect(restored.draft(accountRef: "account-a", groupIdHex: "group-b") == "first account, second group")
        #expect(restored.draft(accountRef: "account-b", groupIdHex: "group-a") == "second account")
        #expect(restored.draft(accountRef: "account-b", groupIdHex: "group-b") == nil)
    }

    @Test func mentionIdentityPersistsWithItsDraftOccurrence() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let npub = try #require(NostrProfileReference.npub(
            fromAccountIdHex: String(repeating: "11", count: 32)
        ))
        let snapshot = ConversationDraftSnapshot(
            text: "ask @Alex",
            mentions: [
                ConversationDraftMention(
                    utf16Location: "ask ".utf16.count,
                    utf16Length: "@Alex".utf16.count,
                    displayName: "Alex",
                    npub: npub
                ),
            ]
        )

        let first = ConversationDraftStore(fileURL: fixture.file)
        await first.loadIfNeeded()
        first.setDraft(snapshot, accountRef: "account", groupIdHex: "group")
        await first.flush()

        let restored = ConversationDraftStore(fileURL: fixture.file)
        await restored.loadIfNeeded()
        #expect(restored.snapshot(accountRef: "account", groupIdHex: "group") == snapshot)
    }

    @Test func legacyDraftDocumentWithoutMentionMetadataStillLoads() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let legacyDocument = """
        {
          "version": 1,
          "entries": [
            {
              "key": { "accountRef": "account", "groupIdHex": "group" },
              "text": "legacy draft",
              "updatedAt": 1
            }
          ]
        }
        """
        try #require(legacyDocument.data(using: .utf8)).write(to: fixture.file)

        let store = ConversationDraftStore(fileURL: fixture.file)
        await store.loadIfNeeded()

        #expect(store.snapshot(accountRef: "account", groupIdHex: "group") == ConversationDraftSnapshot(
            text: "legacy draft",
            mentions: []
        ))
    }

    @Test func invalidPersistedMentionRangesAreDiscardedWithoutLosingText() async {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = ConversationDraftStore(fileURL: fixture.file)
        await store.loadIfNeeded()
        let snapshot = ConversationDraftSnapshot(
            text: "ask @Alex",
            mentions: [
                ConversationDraftMention(
                    utf16Location: Int.max,
                    utf16Length: Int.max,
                    displayName: "Alex",
                    npub: "invalid"
                ),
            ]
        )

        store.setDraft(snapshot, accountRef: "account", groupIdHex: "group")

        #expect(store.snapshot(accountRef: "account", groupIdHex: "group") == ConversationDraftSnapshot(
            text: snapshot.text,
            mentions: []
        ))
    }

    @Test func blankDraftsAreRemovedAndStoredTextIsBoundedWithoutRewritingContent() async {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = ConversationDraftStore(fileURL: fixture.file)
        await store.loadIfNeeded()

        let exact = "  First line\nsecond line  "
        store.setDraft(exact, accountRef: "account", groupIdHex: "group")
        #expect(store.draft(accountRef: "account", groupIdHex: "group") == exact)

        store.setDraft(" \n\t ", accountRef: "account", groupIdHex: "group")
        #expect(store.draft(accountRef: "account", groupIdHex: "group") == nil)

        let oversized = String(repeating: "x", count: ContentSanitizer.maxMessageLength + 100)
        store.setDraft(oversized, accountRef: "account", groupIdHex: "group")
        #expect(store.draft(accountRef: "account", groupIdHex: "group")?.count == ContentSanitizer.maxMessageLength)
    }

    @Test func removingAnAccountKeepsOtherAccountsDrafts() async {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = ConversationDraftStore(fileURL: fixture.file)
        await store.loadIfNeeded()
        store.setDraft("remove", accountRef: "account-a", groupIdHex: "group")
        store.setDraft("keep", accountRef: "account-b", groupIdHex: "group")

        store.removeDrafts(accountRef: "account-a")

        #expect(store.draft(accountRef: "account-a", groupIdHex: "group") == nil)
        #expect(store.draft(accountRef: "account-b", groupIdHex: "group") == "keep")
    }

    @Test func backgroundSuspensionFlushesTheLatestDraftImmediately() async throws {
        let fixture = makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = ConversationDraftStore(fileURL: fixture.file)
        await store.loadIfNeeded()
        let appState = AppState(
            client: try MarmotClient.testClient(),
            notifications: .shared,
            conversationDraftStore: store
        )

        store.setDraft("last keystrokes", accountRef: "account", groupIdHex: "group")
        await appState.startRuntimeSuspension().value

        let restored = ConversationDraftStore(fileURL: fixture.file)
        await restored.loadIfNeeded()
        #expect(restored.draft(accountRef: "account", groupIdHex: "group") == "last keystrokes")
    }

    @Test func chatListPreviewCollapsesLinesAndUnsafeFormatting() {
        let preview = ConversationDraftPreview.text(
            from: "  First\u{202E}\nsecond\u{200B}  "
        )

        #expect(preview == "First second")
    }

    private func makeFixture() -> (root: URL, file: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ConversationDraftStoreTests-\(UUID().uuidString)", isDirectory: true)
        return (root, root.appendingPathComponent("drafts.json"))
    }
}
