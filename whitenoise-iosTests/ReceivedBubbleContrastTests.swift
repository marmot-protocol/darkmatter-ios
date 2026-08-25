import Testing
import UIKit
@testable import whitenoise_ios

/// Other-user bubbles use the prototype's opaque semantic gray surface.
@MainActor
struct ReceivedBubbleContrastTests {

    @Test func darkModeUsesLighterGrayThanBackground() {
        #expect(MessageBubble.receivedBubbleColor(dark: true) == UIColor.systemGray5)
    }

    @Test func lightModeUsesPrototypeGray() {
        #expect(MessageBubble.receivedBubbleColor(dark: false) == UIColor.systemGray5)
    }
}

@MainActor
struct MessageBubbleReplyChromeTests {

    @Test func bubbleChromeUsesPrototypeMetrics() {
        #expect(MessageBubbleReplyLayout.bodyHorizontalInset == 12)
        #expect(MessageBubbleReplyLayout.bodyTopInset == 8)
        #expect(MessageBubbleReplyLayout.bodyBottomInset == 8)
        #expect(ChatBubbleMetrics.cornerRadius == 18)
    }

    @Test func replyCardUsesPrototypeInsetAndCornerMetrics() {
        #expect(MessageBubbleReplyLayout.richContentWidth == 256)
        #expect(MessageBubbleReplyLayout.richBubbleWidth == 268)
        #expect(MessageBubbleReplyLayout.cardOuterInset == 6)
        #expect(MessageBubbleReplyLayout.cardHorizontalInset == 10)
        #expect(MessageBubbleReplyLayout.cardVerticalInset == 6)
        #expect(MessageBubbleReplyLayout.cardCornerRadius == 12)
        #expect(MessageBubbleReplyLayout.bodyTopInsetAfterReply == 0)
        #expect(MessageBubbleReplyLayout.bodyBottomInset == MessageBubbleReplyLayout.bodyTopInset)
    }

    @Test func replyCardsUseThePrototypeSurfaceOpacities() {
        #expect(MessageBubbleReplyLayout.receivedCardOpacity == 0.09)
        #expect(MessageBubbleReplyLayout.sentCardOpacity == 0.16)
    }

    @Test func replyCardTintRemainsSubtle() {
        #expect(MessageBubbleReplyLayout.receivedCardOpacity > 0)
        #expect(MessageBubbleReplyLayout.sentCardOpacity < 0.25)
    }
}

struct MessageBubbleMetadataLayoutTests {
    @Test func timestampsAlwaysUseTheOuterConversationEdge() {
        #expect(!MessageMetadataRowArrangement.timestampOnLeadingEdge(isFromMe: true))
        #expect(MessageMetadataRowArrangement.timestampOnLeadingEdge(isFromMe: false))
    }

    @Test func chromeWidthTracksItsWidestChildAndHonorsTheProposal() {
        #expect(MessageBubbleChromeSizing.width(
            proposedWidth: 320,
            bubbleWidth: 140,
            metadataWidth: 180
        ) == 180)
        #expect(MessageBubbleChromeSizing.width(
            proposedWidth: 150,
            bubbleWidth: 280,
            metadataWidth: 180
        ) == 150)
        #expect(MessageBubbleChromeSizing.width(
            proposedWidth: nil,
            bubbleWidth: 140,
            metadataWidth: 180
        ) == 180)
    }

    @Test func chromeHeightAddsBubbleMetadataAndSpacing() {
        #expect(MessageBubbleChromeSizing.height(
            bubbleHeight: 44,
            metadataHeight: 14,
            spacing: 3
        ) == 61)
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

    @Test func manyLineMessagesCollapseByLineCount() {
        let body = Array(repeating: "line", count: MessageBodyCollapsePresentation.maxCollapsedLines + 1)
            .joined(separator: "\n")
        #expect(MessageBodyCollapsePresentation.shouldCollapse(body))
    }

    @Test func expandingALongMessageRemovesTheInlineCollapse() {
        let body = String(repeating: "x", count: MessageBodyCollapsePresentation.maxCollapsedCharacters + 1)
        #expect(MessageBodyCollapsePresentation.isCollapsed(body, isExpanded: false))
        #expect(!MessageBodyCollapsePresentation.isCollapsed(body, isExpanded: true))
    }
}
