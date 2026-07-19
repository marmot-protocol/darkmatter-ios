import Testing
@testable import whitenoise_ios

/// #54 — outbound message send must clamp text to the protocol's max length so
/// an oversized paste can't bypass the composer's cap.
struct OutboundMessageCapTests {

    @Test func clampsOversizedTextToMaxMessageLength() {
        let huge = String(repeating: "x", count: ContentSanitizer.maxMessageLength + 250)
        #expect(ConversationViewModel.cappedOutgoingText(huge).count == ContentSanitizer.maxMessageLength)
    }

    @Test func leavesTextWithinLimitUnchanged() {
        #expect(ConversationViewModel.cappedOutgoingText("hello") == "hello")
        let exact = String(repeating: "y", count: ContentSanitizer.maxMessageLength)
        #expect(ConversationViewModel.cappedOutgoingText(exact) == exact)
    }

    @Test func dropsWholeCanonicalMentionInsteadOfEmittingPartialNpub() throws {
        let npub = try #require(NostrProfileReference.npub(
            fromAccountIdHex: String(repeating: "11", count: 32)
        ))
        let prefix = String(repeating: "x", count: ContentSanitizer.maxMessageLength - 6)

        let outgoing = ConversationViewModel.cappedOutgoingText("\(prefix) @\(npub)")

        #expect(outgoing == "\(prefix) ")
    }
}
