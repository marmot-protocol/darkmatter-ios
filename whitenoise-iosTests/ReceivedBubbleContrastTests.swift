import Testing
import UIKit
@testable import whitenoise_ios

/// #4 — other-user bubbles must use a higher-contrast fill in dark mode (a
/// lighter system gray) so they stand off the conversation background.
@MainActor
struct ReceivedBubbleContrastTests {

    @Test func darkModeUsesLighterGrayThanBackground() {
        #expect(MessageBubble.receivedBubbleColor(dark: true) == UIColor.systemGray5)
    }

    @Test func lightModeIsUnchanged() {
        #expect(MessageBubble.receivedBubbleColor(dark: false) == UIColor.secondarySystemBackground)
    }
}

@MainActor
struct MessageBubbleReplyChromeTests {

    @Test func replyHeaderUsesBalancedPaddingAndExtraBodyGap() {
        #expect(MessageBubbleReplyLayout.headerVerticalInset > 0)
        #expect(MessageBubbleReplyLayout.headerHorizontalInset == MessageBubbleReplyLayout.bodyHorizontalInset)
        #expect(MessageBubbleReplyLayout.bodyTopInsetAfterReply > MessageBubbleReplyLayout.bodyTopInset)
        #expect(MessageBubbleReplyLayout.bodyBottomInset == MessageBubbleReplyLayout.bodyTopInset)
    }

    @Test func receivedReplyHeaderContrastsWithBubbleFill() {
        #expect(MessageBubble.receivedReplyHeaderColor(dark: true) == UIColor.systemGray4)
        #expect(MessageBubble.receivedReplyHeaderColor(dark: false) == UIColor.systemGray5)
        #expect(MessageBubble.receivedReplyHeaderColor(dark: true) != MessageBubble.receivedBubbleColor(dark: true))
        #expect(MessageBubble.receivedReplyHeaderColor(dark: false) != MessageBubble.receivedBubbleColor(dark: false))
    }

    @Test func sentReplyHeaderUsesSubtleOverlay() {
        #expect(MessageBubbleReplyLayout.sentHeaderOverlayOpacity > 0)
        #expect(MessageBubbleReplyLayout.sentHeaderOverlayOpacity < 0.25)
    }
}

struct MessageBodyCollapsePresentationTests {
    @Test func shortMessagesStayExpanded() {
        #expect(!MessageBodyCollapsePresentation.shouldCollapse("Short message"))
    }

    @Test func veryLongMessagesCollapseByCharacterCount() {
        let body = String(repeating: "x", count: MessageBodyCollapsePresentation.maxCollapsedCharacters + 1)
        #expect(MessageBodyCollapsePresentation.shouldCollapse(body))
    }

    @Test func disabledCollapseKeepsLongMessagesExpanded() {
        let body = String(repeating: "x", count: MessageBodyCollapsePresentation.maxCollapsedCharacters + 1)
        #expect(!MessageBodyCollapsePresentation.shouldCollapse(body, collapseLongMessages: false))
    }

    @Test func manyLineMessagesCollapseByLineCount() {
        let body = Array(repeating: "line", count: MessageBodyCollapsePresentation.maxCollapsedLines + 1)
            .joined(separator: "\n")
        #expect(MessageBodyCollapsePresentation.shouldCollapse(body))
    }
}

struct ConversationLongMessageCollapsePreferenceTests {
    @Test func disabledKeyIsScopedByGroupId() {
        #expect(ConversationLongMessageCollapsePreference.disabledKey(forGroupIdHex: "abc").hasSuffix(".abc"))
        #expect(
            ConversationLongMessageCollapsePreference.disabledKey(forGroupIdHex: "abc")
                != ConversationLongMessageCollapsePreference.disabledKey(forGroupIdHex: "def")
        )
    }
}
