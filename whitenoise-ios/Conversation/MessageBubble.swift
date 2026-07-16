import SwiftUI
import UIKit
import MarmotKit
import ImageIO
import AVFoundation
import AVKit

/// Reference box for the media-load callback. Passing the bare async closure
/// through every media view layer builds a deep reabstraction-thunk chain
/// that corrupts the indirect argument in debug builds — one shared box keeps
/// each hop a plain reference copy and the call a direct method dispatch.
@MainActor
final class ConversationMediaLoader {
    private let load: (MessageMediaAttachment) async throws -> Data

    init(_ load: @escaping (MessageMediaAttachment) async throws -> Data) {
        self.load = load
    }

    func data(for media: MessageMediaAttachment) async throws -> Data {
        try await load(media)
    }
}

enum MessageBubbleReplyLayout {
    static let bodyHorizontalInset: CGFloat = 14
    static let bodyTopInset: CGFloat = 9
    static let bodyTopInsetAfterReply: CGFloat = 11
    static let bodyBottomInset: CGFloat = 9
    static let headerHorizontalInset = bodyHorizontalInset
    static let headerVerticalInset: CGFloat = 8
    static let sentHeaderOverlayOpacity = 0.16
}

private struct ReplyHeaderHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ReplyHeaderWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct MessageBodyContentWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

nonisolated enum MessageBodyCollapsePresentation {
    static let maxCollapsedCharacters = 900
    static let maxCollapsedLines = 12
    static let collapsedBodyMaxHeight: CGFloat = 260

    static func shouldCollapse(_ text: String) -> Bool {
        text.count > maxCollapsedCharacters || lineCount(text) > maxCollapsedLines
    }

    static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.split(separator: "\n", omittingEmptySubsequences: false).count
    }
}

/// One chat bubble. Aligned right for our own messages, left for everyone
/// else. Renders an optional quoted reply header, the message body, a
/// time/delivery caption, and any reaction chips.
struct MessageBubble: View {
    @Environment(AppState.self) private var appState
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.openURL) private var openURL
    let record: AppMessageRecordFfi
    let status: MessageStatus
    var debugStyle: MessageDebugStyle? = nil
    var isDeleted: Bool = false
    var isEdited: Bool = false
    var replyPreview: (name: String, text: String)? = nil
    var mediaItems: [MessageMediaAttachment] = []
    var markdownBlocks: [MarkdownDisplayBlock]? = nil
    var reactions: [ConversationViewModel.ReactionTally] = []
    var onShowReactionDetails: (String) -> Void = { _ in }
    var onReplyPreviewTap: () -> Void = {}
    var onLoadMedia = ConversationMediaLoader { _ in Data() }
    /// Set when the message has viewable edit history; makes the inline "Edited"
    /// label tap to open the history sheet, the same sheet the actions menu opens.
    var onViewEditHistory: (() -> Void)? = nil

    @State private var mediaGallery: MessageMediaGallery?
    @State private var fullBodyPresentation: MessageFullBodyPresentation?
    @State private var pendingExternalLink: PendingMessageExternalLink?
    @State private var replyHeaderHeight: CGFloat = 0
    @State private var replyHeaderWidth: CGFloat = 0
    @State private var measuredBodyContentWidth: CGFloat = 0

    private var isFromMe: Bool { record.direction == "sent" }

    private var bubbleMaxWidth: CGFloat? {
        sizeClass == .regular ? ChatBubbleMetrics.regularMaximumWidth : nil
    }

    /// Minimum gap on the opposite side. Tiny on iPhone so long bubbles run
    /// (near) full width; larger on iPad where width is also capped above.
    private var oppositeInset: CGFloat {
        sizeClass == .regular ? ChatBubbleMetrics.regularOppositeInset : ChatBubbleMetrics.compactOppositeInset
    }

    /// Body text projected from the decoded unsigned Nostr app event's kind,
    /// tags, and content.
    private var bodyText: String {
        Self.bodyText(
            for: record,
            hasMediaItems: !mediaItems.isEmpty,
            mentionDisplayName: { appState.mentionDisplayName(for: $0) }
        )
    }

    static func bodyText(
        for record: AppMessageRecordFfi,
        hasMediaItems: Bool,
        mentionDisplayName: MarkdownMentionResolver? = nil
    ) -> String {
        if hasMediaItems {
            return record.plaintext
        }
        return MessagePreview.body(record, mentionDisplayName: mentionDisplayName)
    }

    private var sanitizedBodyText: String {
        ContentSanitizer.messageBody(bodyText)
    }

    private var hasVisibleBodyText: Bool {
        if debugStyle != nil, debugStyle?.isUserVisibleBubble == false {
            return true
        }
        return !sanitizedBodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var showsStandardBody: Bool {
        debugStyle?.isUserVisibleBubble ?? true
    }

    /// White-on-gradient text is only appropriate for our own user-visible bubbles.
    private var usesSentBubbleForeground: Bool {
        isFromMe && showsStandardBody
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            if isFromMe { Spacer(minLength: oppositeInset) }

            VStack(alignment: isFromMe ? .trailing : .leading, spacing: 2) {
                if !isFromMe {
                    Text(appState.displayName(forAccountIdHex: record.sender))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                }

                if isDeleted {
                    deletedBubble
                } else if !mediaItems.isEmpty, showsStandardBody {
                    mediaMessageContent
                } else {
                    textBubble
                        .opacity(status == .sending ? 0.7 : 1)

                    if !reactions.isEmpty, showsStandardBody {
                        reactionChips
                    }
                }

            }
            .frame(maxWidth: bubbleMaxWidth, alignment: isFromMe ? .trailing : .leading)

            if !isFromMe { Spacer(minLength: oppositeInset) }
        }
        .padding(.horizontal, 12)
        .fullScreenCover(item: $mediaGallery) { gallery in
            MessageMediaFullscreenGalleryView(
                gallery: gallery,
                onLoadMedia: onLoadMedia
            ) {
                mediaGallery = nil
            }
        }
        .fullScreenCover(item: $fullBodyPresentation) { presentation in
            MessageFullBodyView(
                presentation: presentation,
                onClose: { fullBodyPresentation = nil }
            )
            .environment(\.openURL, OpenURLAction(handler: handleMessageLink))
        }
        .alert(L10n.string("Open link?"), isPresented: externalLinkConfirmationPresented) {
            Button(L10n.string("Open")) {
                guard let link = pendingExternalLink else { return }
                pendingExternalLink = nil
                openURL(link.url)
            }
            Button("Cancel", role: .cancel) {
                pendingExternalLink = nil
            }
        } message: {
            Text(pendingExternalLink?.displayText ?? "")
        }
    }

    private var deletedBubble: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "trash")
                Text("This message was deleted")
            }
            messageMetadataFooter
        }
        .font(.callout)
        .italic()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4]))
        )
    }

    private func replyHeader(_ preview: (name: String, text: String)) -> some View {
        Button(action: onReplyPreviewTap) {
            quoted(preview)
                .padding(.horizontal, MessageBubbleReplyLayout.headerHorizontalInset)
                .padding(.vertical, MessageBubbleReplyLayout.headerVerticalInset)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(
                            key: ReplyHeaderHeightPreferenceKey.self,
                            value: geometry.size.height
                        )
                        .preference(
                            key: ReplyHeaderWidthPreferenceKey.self,
                            value: geometry.size.width
                        )
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.formatted("Reply to %@", preview.name))
        .onPreferenceChange(ReplyHeaderHeightPreferenceKey.self) { replyHeaderHeight = $0 }
        .onPreferenceChange(ReplyHeaderWidthPreferenceKey.self) { replyHeaderWidth = $0 }
    }

    private var textBubble: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let debugStyle {
                debugHeader(debugStyle)
            }
            if let replyPreview, showsStandardBody {
                replyHeader(replyPreview)
            }
            if showsStandardBody {
                messageBodyText(hasReply: replyPreview != nil)
                if let debugStyle, debugStyle.isUserVisibleBubble {
                    debugTagsFooter(debugStyle)
                }
            } else if let debugStyle {
                debugPayload(debugStyle)
                messageMetadataFooter
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, MessageBubbleReplyLayout.bodyHorizontalInset)
                    .padding(.bottom, MessageBubbleReplyLayout.bodyBottomInset)
            }
        }
        .font(.body)
        .background { bubbleLayerBackground(hasReply: replyPreview != nil) }
        .clipShape(.rect(cornerRadius: 18))
        .overlay {
            if let debugStyle {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(debugStyle.category.accentColor.opacity(0.75), lineWidth: 2)
            }
        }
        // No .textSelection here: it installs its own long-press recognizer
        // that swallows the bubble's long-press. Copy is in the actions sheet.
    }

    private func debugHeader(_ style: MessageDebugStyle) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(style.category.label)
                    .font(.caption2.weight(.semibold))
                Spacer(minLength: 0)
                Text(style.kindLabel)
                    .font(.caption2.monospaced())
            }
            .foregroundStyle(style.category.accentColor)
        }
        .padding(.horizontal, MessageBubbleReplyLayout.bodyHorizontalInset)
        .padding(.top, MessageBubbleReplyLayout.bodyTopInset)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.category.accentColor.opacity(0.12))
    }

    private func debugTagsFooter(_ style: MessageDebugStyle) -> some View {
        Text(style.tagsSummary)
            .font(.caption2.monospaced())
            .foregroundStyle(usesSentBubbleForeground ? Color.white.opacity(0.78) : Color.secondary)
            .textSelection(.enabled)
            .padding(.horizontal, MessageBubbleReplyLayout.bodyHorizontalInset)
            .padding(.bottom, MessageBubbleReplyLayout.bodyBottomInset)
    }

    private func debugPayload(_ style: MessageDebugStyle) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(style.detailText)
                .font(.caption.monospaced())
                .foregroundStyle(usesSentBubbleForeground ? Color.white.opacity(0.95) : Color.primary)
                .textSelection(.enabled)
            Text(style.tagsSummary)
                .font(.caption2.monospaced())
                .foregroundStyle(usesSentBubbleForeground ? Color.white.opacity(0.82) : Color.secondary)
                .textSelection(.enabled)
            if !record.messageIdHex.isEmpty {
                Text("id: \(record.messageIdHex)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(usesSentBubbleForeground ? Color.white.opacity(0.72) : Color.secondary.opacity(0.8))
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, MessageBubbleReplyLayout.bodyHorizontalInset)
        .padding(.top, MessageBubbleReplyLayout.bodyTopInsetAfterReply)
        .padding(.bottom, MessageBubbleReplyLayout.bodyBottomInset)
    }

    @ViewBuilder
    private var mediaMessageContent: some View {
        VStack(alignment: isFromMe ? .trailing : .leading, spacing: 6) {
            MessageMediaAttachmentContent(
                items: mediaItems,
                isFromMe: isFromMe,
                maxWidth: mediaGridWidth,
                onLoadMedia: onLoadMedia,
                onOpenImage: { item, data in
                    mediaGallery = MessageMediaGallery(
                        items: mediaItems,
                        initialItem: item,
                        initialImageData: data
                    )
                },
                onOpenVideo: { item in
                    mediaGallery = MessageMediaGallery(
                        items: mediaItems,
                        initialItem: item
                    )
                }
            )
            .overlay(alignment: .bottomTrailing) {
                if !hasVisibleBodyText && replyPreview == nil {
                    mediaOverlayMetadataFooter
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.42), in: Capsule())
                        .padding(6)
                }
            }

            if let replyPreview {
                VStack(alignment: .leading, spacing: 0) {
                    replyHeader(replyPreview)
                    if hasVisibleBodyText {
                        messageBodyText(hasReply: true)
                    } else {
                        messageMetadataFooter
                            .padding(.horizontal, MessageBubbleReplyLayout.bodyHorizontalInset)
                            .padding(.bottom, MessageBubbleReplyLayout.bodyBottomInset)
                    }
                }
                .font(.body)
                .background { bubbleLayerBackground(hasReply: true) }
                .clipShape(.rect(cornerRadius: 18))
            } else if hasVisibleBodyText {
                textBubble
            }
        }
        .opacity(status == .sending ? 0.7 : 1)

        if !reactions.isEmpty {
            reactionChips
        }
    }

    private var mediaGridWidth: CGFloat {
        sizeClass == .regular ? 340 : 276
    }

    private func quoted(_ preview: (name: String, text: String)) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(isFromMe ? Color.white.opacity(0.8) : Color.accentColor)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                Text(preview.name)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isFromMe ? Color.white.opacity(0.95) : Color.primary)
                Text(preview.text)
                    .font(.caption)
                    .foregroundStyle(isFromMe ? Color.white.opacity(0.82) : Color.secondary)
                    .lineLimit(1)
            }
        }
        // Without this the width-only Capsule is greedy vertically and stretches
        // the whole bubble; fixedSize pins the quote to its content height.
        .fixedSize(horizontal: false, vertical: true)
    }

    private func messageBodyText(hasReply: Bool) -> some View {
        let shouldCollapse = MessageBodyCollapsePresentation.shouldCollapse(sanitizedBodyText)
        let usesInlineFooter = MessageBubbleTextLayout.usesInlineFooter(
            text: sanitizedBodyText,
            isCollapsed: shouldCollapse
        )
        let replyContentWidth = hasReply && replyHeaderWidth > 0
            ? max(0, replyHeaderWidth - (MessageBubbleReplyLayout.bodyHorizontalInset * 2))
            : 0
        let bodyLayoutWidth: CGFloat? = max(replyContentWidth, measuredBodyContentWidth) > 0
            ? max(replyContentWidth, measuredBodyContentWidth)
            : nil
        return Group {
            if usesInlineFooter {
                if hasReply {
                    HStack(alignment: .lastTextBaseline, spacing: 0) {
                        messageBodyContent
                            .layoutPriority(1)
                        Spacer(minLength: 7)
                        messageMetadataFooter
                            .fixedSize()
                    }
                    .frame(
                        minWidth: replyContentWidth > 0 ? replyContentWidth : nil,
                        alignment: .leading
                    )
                } else {
                    HStack(alignment: .lastTextBaseline, spacing: 7) {
                        messageBodyContent
                            .layoutPriority(1)
                        messageMetadataFooter
                            .fixedSize()
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    messageBodyContent
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: MessageBodyContentWidthPreferenceKey.self,
                                    value: geometry.size.width
                                )
                            }
                        }
                        .frame(width: bodyLayoutWidth, alignment: .leading)
                        .frame(
                            maxHeight: shouldCollapse ? MessageBodyCollapsePresentation.collapsedBodyMaxHeight : nil,
                            alignment: .topLeading
                        )
                        .clipped()

                    if shouldCollapse {
                        HStack(alignment: .lastTextBaseline, spacing: 8) {
                            Button {
                                fullBodyPresentation = MessageFullBodyPresentation(
                                    id: record.messageIdHex.isEmpty
                                        ? "pending-\(record.recordedAt)"
                                        : record.messageIdHex,
                                    text: sanitizedBodyText,
                                    blocks: markdownBlocks
                                )
                            } label: {
                                Text(L10n.string("Read more"))
                                    .font(.footnote.weight(.semibold))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(isFromMe ? Color.white.opacity(0.9) : Color.accentColor)

                            Spacer(minLength: 8)
                            messageMetadataFooter
                                .fixedSize()
                        }
                        .frame(width: bodyLayoutWidth, alignment: .leading)
                    } else {
                        messageMetadataFooter
                            .background {
                                GeometryReader { geometry in
                                    Color.clear.preference(
                                        key: MessageBodyContentWidthPreferenceKey.self,
                                        value: geometry.size.width
                                    )
                                }
                            }
                            .frame(width: bodyLayoutWidth, alignment: .trailing)
                    }
                }
            }
        }
        .foregroundStyle(isFromMe ? Color.white : Color.primary)
        .padding(.horizontal, MessageBubbleReplyLayout.bodyHorizontalInset)
        .padding(.top, hasReply ? MessageBubbleReplyLayout.bodyTopInsetAfterReply : MessageBubbleReplyLayout.bodyTopInset)
        .padding(.bottom, MessageBubbleReplyLayout.bodyBottomInset)
        .onPreferenceChange(MessageBodyContentWidthPreferenceKey.self) {
            measuredBodyContentWidth = $0
        }
    }

    @ViewBuilder
    private var messageBodyContent: some View {
        if let blocks = markdownBlocks {
            MarkdownMessageView(
                blocks: blocks,
                quoteBar: isFromMe ? Color.white.opacity(0.8) : Color.accentColor
            )
            .tint(isFromMe ? Color.white : Color.accentColor)
            .environment(\.openURL, OpenURLAction(handler: handleMessageLink))
        } else {
            // Records without parsed tokens (non-chat kinds, optimistic
            // stream bubbles, pre-markdown history) keep the plain path.
            Text(sanitizedBodyText)
        }
    }

    private func handleMessageLink(_ url: URL) -> OpenURLAction.Result {
        switch MessageLinkPolicy.action(for: url) {
        case .openProfile(let npub):
            appState.presentProfile(npub: npub)
            return .handled
        case .openChat(let groupIdHex):
            appState.presentChat(groupIdHex: groupIdHex)
            return .handled
        case .confirmExternal(let external):
            pendingExternalLink = PendingMessageExternalLink(url: external)
            return .handled
        case .blocked:
            return .discarded
        }
    }

    private var externalLinkConfirmationPresented: Binding<Bool> {
        Binding(
            get: { pendingExternalLink != nil },
            set: { isPresented in
                if !isPresented {
                    pendingExternalLink = nil
                }
            }
        )
    }

    @ViewBuilder
    private var replyHeaderBackground: some View {
        if isFromMe {
            Color.white.opacity(MessageBubbleReplyLayout.sentHeaderOverlayOpacity)
        } else {
            Color(UIColor { traits in
                Self.receivedReplyHeaderColor(dark: traits.userInterfaceStyle == .dark)
            })
        }
    }

    private func bubbleLayerBackground(hasReply: Bool) -> some View {
        ZStack(alignment: .top) {
            bubbleBackground
            if hasReply, replyHeaderHeight > 0 {
                replyHeaderBackground
                    .frame(height: replyHeaderHeight)
            }
        }
    }

    private var reactionChips: some View {
        HStack(spacing: 4) {
            ForEach(ReactionPillPresentation.values(from: reactions)) { tally in
                Button {
                    if !tally.isOverflow {
                        onShowReactionDetails(tally.emoji)
                    }
                } label: {
                    HStack(spacing: 2) {
                        Text(tally.isOverflow ? "+" : ContentSanitizer.reactionEmoji(tally.emoji))
                        if tally.count > 1 || tally.isOverflow {
                            Text(L10n.formatted("%lld", Int64(tally.count)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(tally.mine ? Color.accentColor.opacity(0.22) : Color(.tertiarySystemFill))
                    )
                    .overlay(
                        Capsule().stroke(tally.mine ? Color.accentColor.opacity(0.5) : .clear, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
                .disabled(tally.isOverflow)
            }
        }
        .font(.footnote)
        .padding(isFromMe ? .trailing : .leading, 8)
        .offset(y: -5)
        .padding(.bottom, -5)
    }

    private var messageMetadataFooter: some View {
        MessageMetadataFooter(
            time: timeLabel,
            isEdited: isEdited && !isDeleted,
            status: status,
            isFromMe: isFromMe,
            usesLightForeground: usesSentBubbleForeground,
            onViewEditHistory: onViewEditHistory
        )
    }

    private var mediaOverlayMetadataFooter: some View {
        MessageMetadataFooter(
            time: timeLabel,
            isEdited: isEdited && !isDeleted,
            status: status,
            isFromMe: isFromMe,
            usesLightForeground: true,
            onViewEditHistory: onViewEditHistory
        )
    }

    private var timeLabel: String {
        Self.timeLabel(recordedAt: record.recordedAt)
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if let debugStyle, !debugStyle.isUserVisibleBubble {
            Color(UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor.systemGray5
                    : UIColor.secondarySystemBackground
            })
        } else if isFromMe {
            LinearGradient(
                colors: [.blue, .indigo],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            Color(UIColor { traits in
                Self.receivedBubbleColor(dark: traits.userInterfaceStyle == .dark)
            })
        }
    }

    /// Fill for an incoming (other-user) message bubble. In dark mode the old
    /// `tertiarySystemBackground` sat too close to the elevated conversation
    /// background, so received bubbles barely stood out (#4). Use a lighter
    /// system gray that clearly separates the bubble while keeping the white
    /// message text well above the WCAG AA contrast ratio. Light mode is
    /// unchanged.
    static func receivedBubbleColor(dark: Bool) -> UIColor {
        dark ? .systemGray5 : .secondarySystemBackground
    }

    static func receivedReplyHeaderColor(dark: Bool) -> UIColor {
        dark ? .systemGray4 : .systemGray5
    }

    static func timeLabel(recordedAt: UInt64, locale: Locale = .autoupdatingCurrent) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(recordedAt))
        return RelativeTime.shortTime(date, locale: locale)
    }
}

private struct MessageFullBodyPresentation: Identifiable {
    let id: String
    let text: String
    let blocks: [MarkdownDisplayBlock]?
}

private struct MessageFullBodyView: View {
    let presentation: MessageFullBodyPresentation
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                if let blocks = presentation.blocks {
                    MarkdownMessageView(blocks: blocks)
                        .tint(.accentColor)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                } else {
                    Text(presentation.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
            }
            .navigationTitle(L10n.string("Full message"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L10n.string("Done"), action: onClose)
                }
            }
        }
    }
}

private struct PendingMessageExternalLink: Equatable {
    let url: URL

    var displayText: String {
        MessageExternalLinkConfirmation.displayText(for: url)
    }
}

nonisolated enum MessageExternalLinkConfirmation {
    private static let maxDisplayedHostCharacters = 96
    private static let maxDisplayedURLCharacters = 180

    static func displayText(for url: URL) -> String {
        let displayedURL = elided(ContentSanitizer.textRun(url.absoluteString), maxCharacters: maxDisplayedURLCharacters)
        if let host = hostDisplay(for: url) {
            return L10n.formatted("This link opens %@:\n%@", host, displayedURL)
        }
        return L10n.formatted("This link opens:\n%@", displayedURL)
    }

    private static func hostDisplay(for url: URL) -> String? {
        guard let rawHost = url.host(percentEncoded: false), !rawHost.isEmpty else {
            return nil
        }

        let sanitizedHost = ContentSanitizer.textRun(rawHost)

        // Hosts wider than the display cap are peer-controlled (autolinks in
        // received markdown) and are elided away anyway, so never feed an
        // over-long string to the punycode decoder. `decodePunycodeLabel`
        // grows its output with O(n) `Array.insert(_:at:)` calls, so decoding
        // a multi-thousand-character `xn--` label is O(L²) work on the
        // MainActor at tap time. Bounding the input before decode keeps that
        // cost proportional to what we can actually show.
        guard sanitizedHost.count <= maxDisplayedHostCharacters else {
            return elided(sanitizedHost, maxCharacters: maxDisplayedHostCharacters)
        }

        let decoded = decodedInternationalizedHost(sanitizedHost)
        let primary = elided(decoded.host, maxCharacters: maxDisplayedHostCharacters)
        guard decoded.isInternationalized else { return primary }

        let raw = elided(sanitizedHost, maxCharacters: maxDisplayedHostCharacters)
        if raw.caseInsensitiveCompare(decoded.host) == .orderedSame {
            return L10n.formatted("%@ (IDN/punycode)", primary)
        }
        return L10n.formatted("%@ (IDN/punycode: %@)", primary, raw)
    }

    private static func decodedInternationalizedHost(_ host: String) -> (host: String, isInternationalized: Bool) {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        var decodedLabels: [String] = []
        var isInternationalized = host.unicodeScalars.contains { $0.value > 0x7f }

        for label in labels {
            let labelString = String(label)
            if labelString.lowercased().hasPrefix("xn--"),
               let decoded = decodePunycodeLabel(String(labelString.dropFirst(4))) {
                decodedLabels.append(decoded)
                isInternationalized = true
            } else {
                decodedLabels.append(labelString)
            }
        }

        // `decodePunycodeLabel` can emit bidi/control/invisible-format scalars
        // (e.g. U+202E RLO from `xn--paypal-dm0c`), which would visually reorder
        // the host shown in the confirmation alert. The host string was
        // sanitized *before* decode, so re-strip the decoder output with the
        // stricter relay/URL display policy before it is rendered. If nothing
        // renderable survives, fall back to the raw (already-sanitized) host.
        let joined = decodedLabels.joined(separator: ".")
        let safe = ContentSanitizer.relayDisplayLine(joined, maxLength: joined.count) ?? host
        return (safe, isInternationalized)
    }

    private static func elided(_ text: String, maxCharacters: Int) -> String {
        guard text.count > maxCharacters, maxCharacters > 8 else { return text }
        let prefixCount = maxCharacters / 2
        let suffixCount = maxCharacters - prefixCount - 1
        return "\(text.prefix(prefixCount))…\(text.suffix(suffixCount))"
    }

    private static func decodePunycodeLabel(_ input: String) -> String? {
        let scalars = Array(input.unicodeScalars)
        var output: [UInt32] = []
        var index = 0

        if let delimiterIndex = scalars.lastIndex(where: { $0 == "-" }) {
            for scalar in scalars[..<delimiterIndex] {
                guard scalar.value < 0x80 else { return nil }
                output.append(scalar.value)
            }
            index = delimiterIndex + 1
        }

        var n = 128
        var i = 0
        var bias = 72

        while index < scalars.count {
            let oldi = i
            var w = 1
            var k = 36

            while true {
                guard index < scalars.count,
                      let digit = punycodeDigitValue(scalars[index])
                else { return nil }
                index += 1
                guard digit <= (Int.max - i) / w else { return nil }
                i += digit * w

                let t: Int
                if k <= bias {
                    t = 1
                } else if k >= bias + 26 {
                    t = 26
                } else {
                    t = k - bias
                }

                if digit < t { break }
                guard w <= Int.max / (36 - t) else { return nil }
                w *= 36 - t
                k += 36
            }

            let outputCount = output.count + 1
            // Defense in depth against quadratic decode cost: each
            // `output.insert(_:at:)` below shifts O(output.count) elements, so
            // an over-long `xn--` label would be O(L²). Callers already cap the
            // host length, but the decoder must not trust that, so bail to the
            // raw label once the decoded output exceeds what we can display.
            guard outputCount <= maxDisplayedHostCharacters else { return nil }
            bias = adaptPunycodeBias(delta: i - oldi, numPoints: outputCount, firstTime: oldi == 0)
            let (newN, overflowed) = n.addingReportingOverflow(i / outputCount)
            guard !overflowed else { return nil }
            n = newN
            let insertionIndex = i % outputCount
            guard let scalar = UnicodeScalar(n) else { return nil }
            output.insert(scalar.value, at: insertionIndex)
            i = insertionIndex + 1
        }

        var view = String.UnicodeScalarView()
        for value in output {
            guard let scalar = UnicodeScalar(value) else { return nil }
            view.append(scalar)
        }
        return String(view)
    }

    private static func punycodeDigitValue(_ scalar: UnicodeScalar) -> Int? {
        switch scalar.value {
        case 48...57: Int(scalar.value - 22) // 0...9 => 26...35
        case 65...90: Int(scalar.value - 65)
        case 97...122: Int(scalar.value - 97)
        default: nil
        }
    }

    private static func adaptPunycodeBias(delta: Int, numPoints: Int, firstTime: Bool) -> Int {
        var delta = firstTime ? delta / 700 : delta / 2
        delta += delta / numPoints
        var k = 0
        while delta > ((36 - 1) * 26) / 2 {
            delta /= 36 - 1
            k += 36
        }
        return k + (((36 - 1 + 1) * delta) / (delta + 38))
    }
}

private struct MessageMediaGrid: View {
    let items: [MessageMediaAttachment]
    let isFromMe: Bool
    let maxWidth: CGFloat
    let onLoadMedia: ConversationMediaLoader
    let onOpenImage: (MessageMediaAttachment, Data) -> Void
    let onOpenVideo: (MessageMediaAttachment) -> Void

    private let spacing: CGFloat = 2
    private let cornerRadius: CGFloat = 14

    private var visibleItems: [MessageMediaAttachment] {
        Array(items.prefix(MessageMediaGridPresentation.visibleCount(totalCount: items.count)))
    }

    private var hiddenCount: Int {
        MessageMediaGridPresentation.hiddenCount(totalCount: items.count)
    }

    private var columnCount: Int {
        MessageMediaGridPresentation.columnCount(totalCount: items.count)
    }

    private var rowCount: Int {
        MessageMediaGridPresentation.rowCount(totalCount: items.count)
    }

    private var tileSize: CGFloat {
        let totalSpacing = CGFloat(columnCount - 1) * spacing
        return (maxWidth - totalSpacing) / CGFloat(columnCount)
    }

    private var gridHeight: CGFloat {
        CGFloat(rowCount) * tileSize + CGFloat(rowCount - 1) * spacing
    }

    private var rowStarts: [Int] {
        Array(stride(from: 0, to: visibleItems.count, by: columnCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(rowStarts, id: \.self) { rowStart in
                HStack(spacing: spacing) {
                    ForEach(0..<columnCount, id: \.self) { column in
                        tile(at: rowStart + column)
                    }
                }
                .frame(width: maxWidth, alignment: .leading)
            }
        }
        .frame(width: maxWidth, height: gridHeight, alignment: .topLeading)
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.primary.opacity(isFromMe ? 0.16 : 0.08), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func tile(at index: Int) -> some View {
        if index < visibleItems.count {
            let roundedCorners = MessageMediaGridPresentation.roundedCorners(
                totalCount: items.count,
                tileIndex: index
            )
            MessageMediaTile(
                item: visibleItems[index],
                isFromMe: isFromMe,
                size: CGSize(width: tileSize, height: tileSize),
                hiddenCount: index == visibleItems.count - 1 ? hiddenCount : 0,
                onLoadMedia: onLoadMedia,
                onOpenImage: onOpenImage,
                onOpenVideo: onOpenVideo
            )
            .messageMediaTileCornerClip(roundedCorners, radius: cornerRadius)
        } else {
            Color.clear
                .frame(width: tileSize, height: tileSize)
        }
    }
}

private struct MessageMediaTileCornerClip: ViewModifier {
    let corners: MessageMediaTileCornerRadii
    let radius: CGFloat

    @Environment(\.layoutDirection) private var layoutDirection

    @ViewBuilder
    func body(content: Content) -> some View {
        if corners.hasRoundedCorners {
            content.clipShape(MessageMediaRoundedTileShape(
                corners: corners,
                radius: radius,
                layoutDirection: layoutDirection
            ))
        } else {
            content
        }
    }
}

private extension View {
    func messageMediaTileCornerClip(_ corners: MessageMediaTileCornerRadii, radius: CGFloat) -> some View {
        modifier(MessageMediaTileCornerClip(corners: corners, radius: radius))
    }
}

private struct MessageMediaRoundedTileShape: Shape {
    let corners: MessageMediaTileCornerRadii
    let radius: CGFloat
    let layoutDirection: LayoutDirection

    func path(in rect: CGRect) -> Path {
        let roundedCorners = corners.uiRectCorners(layoutDirection: layoutDirection)
        guard !roundedCorners.isEmpty else { return Path(rect) }

        let boundedRadius = min(max(0, radius), rect.width / 2, rect.height / 2)
        return Path(UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: roundedCorners,
            cornerRadii: CGSize(width: boundedRadius, height: boundedRadius)
        ).cgPath)
    }
}

private struct MessageMediaAttachmentContent: View {
    let items: [MessageMediaAttachment]
    let isFromMe: Bool
    let maxWidth: CGFloat
    let onLoadMedia: ConversationMediaLoader
    let onOpenImage: (MessageMediaAttachment, Data) -> Void
    let onOpenVideo: (MessageMediaAttachment) -> Void

    private var usesVisualGrid: Bool {
        !items.isEmpty && items.allSatisfy { $0.isImage || $0.isVideo }
    }

    private var singleVideo: MessageMediaAttachment? {
        items.count == 1 && items[0].isVideo ? items[0] : nil
    }

    private var singleImage: MessageMediaAttachment? {
        items.count == 1 && items[0].isImage ? items[0] : nil
    }

    var body: some View {
        if let singleImage {
            MessageSingleImageBubble(
                item: singleImage,
                isFromMe: isFromMe,
                maxWidth: maxWidth,
                onLoadMedia: onLoadMedia,
                onOpenImage: onOpenImage,
                onOpenVideo: onOpenVideo
            )
        } else if let singleVideo {
            MessageSingleVideoBubble(
                item: singleVideo,
                isFromMe: isFromMe,
                maxWidth: maxWidth,
                onLoadMedia: onLoadMedia
            )
        } else if usesVisualGrid {
            MessageMediaGrid(
                items: items,
                isFromMe: isFromMe,
                maxWidth: maxWidth,
                onLoadMedia: onLoadMedia,
                onOpenImage: onOpenImage,
                onOpenVideo: onOpenVideo
            )
        } else {
            VStack(alignment: isFromMe ? .trailing : .leading, spacing: 6) {
                ForEach(items) { item in
                    switch item.kind {
                    case .image:
                        MessageMediaTile(
                            item: item,
                            isFromMe: isFromMe,
                            size: MessageImageBubblePresentation.displaySize(maxWidth: maxWidth, dim: item.dim),
                            hiddenCount: 0,
                            onLoadMedia: onLoadMedia,
                            onOpenImage: onOpenImage,
                            onOpenVideo: onOpenVideo
                        )
                        .clipShape(.rect(cornerRadius: 14))
                    case .video:
                        MessageSingleVideoBubble(
                            item: item,
                            isFromMe: isFromMe,
                            maxWidth: maxWidth,
                            onLoadMedia: onLoadMedia
                        )
                    case .audio:
                        MessageAudioAttachmentView(
                            item: item,
                            isFromMe: isFromMe,
                            width: maxWidth,
                            onLoadMedia: onLoadMedia
                        )
                    case .document, .unsupported:
                        MessageDocumentAttachmentView(
                            item: item,
                            isFromMe: isFromMe,
                            width: maxWidth,
                            onLoadMedia: onLoadMedia
                        )
                    }
                }
            }
            .frame(width: maxWidth, alignment: isFromMe ? .trailing : .leading)
        }
    }
}

private struct MessageSingleImageBubble: View {
    let item: MessageMediaAttachment
    let isFromMe: Bool
    let maxWidth: CGFloat
    let onLoadMedia: ConversationMediaLoader
    let onOpenImage: (MessageMediaAttachment, Data) -> Void
    let onOpenVideo: (MessageMediaAttachment) -> Void

    private let cornerRadius: CGFloat = 14

    private var size: CGSize {
        MessageImageBubblePresentation.displaySize(maxWidth: maxWidth, dim: item.dim)
    }

    var body: some View {
        MessageMediaTile(
            item: item,
            isFromMe: isFromMe,
            size: size,
            hiddenCount: 0,
            onLoadMedia: onLoadMedia,
            onOpenImage: onOpenImage,
            onOpenVideo: onOpenVideo
        )
        .clipShape(.rect(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.primary.opacity(isFromMe ? 0.16 : 0.08), lineWidth: 1)
        }
    }
}

private struct MessageSingleVideoBubble: View {
    let item: MessageMediaAttachment
    let isFromMe: Bool
    let maxWidth: CGFloat
    let onLoadMedia: ConversationMediaLoader

    private let cornerRadius: CGFloat = 14

    private var size: CGSize {
        MessageVideoBubblePresentation.displaySize(maxWidth: maxWidth, dim: item.dim)
    }

    var body: some View {
        MessageVideoAttachmentView(
            item: item,
            isFromMe: isFromMe,
            width: size.width,
            height: size.height,
            onLoadMedia: onLoadMedia,
            onOpenFullscreen: nil
        )
        .clipShape(.rect(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.primary.opacity(isFromMe ? 0.16 : 0.08), lineWidth: 1)
        }
    }
}

nonisolated struct MessageMediaTileCornerRadii: Equatable, Sendable {
    let topLeading: Bool
    let topTrailing: Bool
    let bottomLeading: Bool
    let bottomTrailing: Bool

    static let none = MessageMediaTileCornerRadii(
        topLeading: false,
        topTrailing: false,
        bottomLeading: false,
        bottomTrailing: false
    )

    var hasRoundedCorners: Bool {
        topLeading || topTrailing || bottomLeading || bottomTrailing
    }

    func uiRectCorners(layoutDirection: LayoutDirection) -> UIRectCorner {
        var roundedCorners: UIRectCorner = []
        let isRightToLeft = layoutDirection == .rightToLeft

        if topLeading { roundedCorners.insert(isRightToLeft ? .topRight : .topLeft) }
        if topTrailing { roundedCorners.insert(isRightToLeft ? .topLeft : .topRight) }
        if bottomLeading { roundedCorners.insert(isRightToLeft ? .bottomRight : .bottomLeft) }
        if bottomTrailing { roundedCorners.insert(isRightToLeft ? .bottomLeft : .bottomRight) }

        return roundedCorners
    }
}

enum MessageMediaGridPresentation {
    static let maxVisibleItems = 5

    static func visibleCount(totalCount: Int) -> Int {
        min(max(totalCount, 0), maxVisibleItems)
    }

    static func hiddenCount(totalCount: Int) -> Int {
        max(0, totalCount - maxVisibleItems)
    }

    static func columnCount(totalCount: Int) -> Int {
        totalCount <= 1 ? 1 : 2
    }

    static func rowCount(totalCount: Int) -> Int {
        let visible = visibleCount(totalCount: totalCount)
        let columns = columnCount(totalCount: totalCount)
        guard visible > 0 else { return 0 }
        return Int(ceil(Double(visible) / Double(columns)))
    }

    static func roundedCorners(totalCount: Int, tileIndex: Int) -> MessageMediaTileCornerRadii {
        let visibleCount = visibleCount(totalCount: totalCount)
        guard tileIndex >= 0, tileIndex < visibleCount else { return .none }

        let columns = columnCount(totalCount: totalCount)
        let rows = rowCount(totalCount: totalCount)
        let row = tileIndex / columns
        let column = tileIndex % columns

        let lastRowItemCount = visibleCount - ((rows - 1) * columns)
        let isOnlyItemInLastRow = row == rows - 1 && lastRowItemCount == 1
        return MessageMediaTileCornerRadii(
            topLeading: row == 0 && column == 0,
            topTrailing: row == 0 && column == columns - 1,
            bottomLeading: row == rows - 1 && column == 0,
            bottomTrailing: row == rows - 1 && (column == columns - 1 || isOnlyItemInLastRow)
        )
    }
}

nonisolated private enum MessageVisualMediaBubblePresentation {
    private static let maximumHeightRatio: CGFloat = 1.35

    static func aspectRatio(dim: String?, fallback: CGFloat) -> CGFloat {
        guard let dim else { return fallback }
        let parts = dim
            .lowercased()
            .split(separator: "x", maxSplits: 1)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]),
              width > 0,
              height > 0
        else {
            return fallback
        }
        let aspectRatio = CGFloat(width / height)
        guard aspectRatio.isFinite else { return fallback }
        return min(4, max(0.25, aspectRatio))
    }

    static func displaySize(maxWidth: CGFloat, dim: String?, fallback: CGFloat) -> CGSize {
        let boundedMaxWidth = max(1, maxWidth)
        let aspectRatio = aspectRatio(dim: dim, fallback: fallback)
        if aspectRatio >= 1 {
            return roundedSize(width: boundedMaxWidth, height: boundedMaxWidth / aspectRatio)
        }

        let maxHeight = boundedMaxWidth * maximumHeightRatio
        let height = min(boundedMaxWidth / aspectRatio, maxHeight)
        return roundedSize(width: min(boundedMaxWidth, height * aspectRatio), height: height)
    }

    private static func roundedSize(width: CGFloat, height: CGFloat) -> CGSize {
        CGSize(
            width: max(1, width.rounded(.toNearestOrAwayFromZero)),
            height: max(1, height.rounded(.toNearestOrAwayFromZero))
        )
    }
}

nonisolated enum MessageImageBubblePresentation {
    static func aspectRatio(dim: String?) -> CGFloat {
        MessageVisualMediaBubblePresentation.aspectRatio(dim: dim, fallback: 1)
    }

    static func displaySize(maxWidth: CGFloat, dim: String?) -> CGSize {
        MessageVisualMediaBubblePresentation.displaySize(maxWidth: maxWidth, dim: dim, fallback: 1)
    }
}

nonisolated enum MessageVideoBubblePresentation {
    private static let fallbackAspectRatio: CGFloat = 16.0 / 9.0
    static let fullscreenButtonSize: CGFloat = 36
    static let fullscreenButtonIconSize: CGFloat = 15
    static let fullscreenButtonInset: CGFloat = 8

    static func aspectRatio(dim: String?) -> CGFloat {
        MessageVisualMediaBubblePresentation.aspectRatio(dim: dim, fallback: fallbackAspectRatio)
    }

    static func displaySize(maxWidth: CGFloat, dim: String?) -> CGSize {
        MessageVisualMediaBubblePresentation.displaySize(
            maxWidth: maxWidth,
            dim: dim,
            fallback: fallbackAspectRatio
        )
    }
}

nonisolated enum MessageVideoThumbnailPresentation {
    static func cacheKey(for item: MessageMediaAttachment) -> String {
        if let hash = item.reference?.plaintextSha256.lowercased(),
           hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
        {
            return "sha256:\(hash)"
        }
        return "item:\(item.id)"
    }
}

nonisolated enum MessageMediaThumbnailPresentation {
    static func cacheKey(for item: MessageMediaAttachment) -> String {
        if let hash = item.reference?.plaintextSha256.lowercased(),
           hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
        {
            return "sha256:\(hash)"
        }
        return "item:\(item.id)"
    }
}

nonisolated enum MessageAudioBubblePresentation {
    static func cacheKey(for item: MessageMediaAttachment) -> String {
        if let hash = item.reference?.plaintextSha256.lowercased(),
           hash.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
        {
            return "sha256:\(hash)"
        }
        return "item:\(item.id)"
    }

    static func durationLabel(_ duration: Double?) -> String? {
        AudioDurationLabel.optionalLabel(for: duration)
    }
}

private struct MessageFullscreenVideo: Identifiable {
    let id: String
    let item: MessageMediaAttachment
    let url: URL
}

private struct MessageMediaTile: View {
    let item: MessageMediaAttachment
    let isFromMe: Bool
    let size: CGSize
    let hiddenCount: Int
    let onLoadMedia: ConversationMediaLoader
    let onOpenImage: (MessageMediaAttachment, Data) -> Void
    let onOpenVideo: (MessageMediaAttachment) -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var loadedImageID: String?
    @State private var isLoading = false
    @State private var didFail = false

    private var thumbnailCacheKey: String {
        MessageMediaThumbnailPresentation.cacheKey(for: item)
    }

    var body: some View {
        ZStack {
            if item.isImage, loadedImageID == item.id, let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .clipped()
            } else if item.isImage {
                imagePlaceholder
            } else if item.isVideo {
                MessageVideoAttachmentView(
                    item: item,
                    isFromMe: isFromMe,
                    width: size.width,
                    height: size.height,
                    onLoadMedia: onLoadMedia,
                    onOpenFullscreen: {
                        onOpenVideo(item)
                    }
                )
            } else {
                filePlaceholder
            }

            if hiddenCount > 0 {
                Color.black.opacity(0.48)
                Text(L10n.formatted("+%lld", Int64(hiddenCount)))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        .task(id: item.id) {
            _ = await loadImageIfNeeded(scale: displayScale)
        }
        .onTapGesture {
            guard item.isImage else { return }
            if didFail {
                Task { await loadImageIfNeeded(scale: displayScale, force: true) }
            } else {
                Task {
                    if let data = await loadImageIfNeeded(scale: displayScale) {
                        onOpenImage(item, data)
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder
    private var imagePlaceholder: some View {
        ZStack {
            MessageMediaPlaceholderBackground(
                thumbhash: item.reference?.thumbhash,
                fallbackSystemName: isLoading || didFail ? nil : "photo",
                width: size.width,
                height: size.height
            )
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if didFail {
                VStack(spacing: 5) {
                    Image(systemName: "arrow.clockwise")
                    Text("Retry")
                        .font(.caption2.weight(.semibold))
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private var filePlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc")
                .font(.title3)
            Text(item.fileName)
                .font(.caption2)
                .lineLimit(2)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.secondary)
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.tertiarySystemFill))
    }

    private func loadImageIfNeeded(scale: CGFloat, force: Bool = false) async -> Data? {
        guard item.isImage else { return nil }
        let maxPixelSize = max(1, Int(ceil(max(size.width, size.height) * scale)))
        if !force {
            if let cachedThumbnail = MessageMediaThumbnailDecoder.cachedThumbnail(
                for: thumbnailCacheKey,
                maxPixelSize: maxPixelSize
            ) {
                image = cachedThumbnail.image
                loadedImageID = item.id
                didFail = false
                return cachedThumbnail.sourceData
            }
        }
        isLoading = true
        didFail = false
        defer { isLoading = false }
        do {
            let data = try await onLoadMedia.data(for: item)
            guard !Task.isCancelled else { return nil }
            guard let decoded = await MessageMediaThumbnailDecoder.image(
                data: data,
                maxPixelSize: maxPixelSize,
                scale: scale
            ) else {
                image = nil
                loadedImageID = item.id
                didFail = true
                return nil
            }
            image = decoded
            loadedImageID = item.id
            MessageMediaThumbnailDecoder.store(
                decoded,
                sourceData: data,
                for: thumbnailCacheKey,
                maxPixelSize: maxPixelSize
            )
            return data
        } catch {
            image = nil
            loadedImageID = item.id
            didFail = true
            return nil
        }
    }
}

private struct MessageMediaPlaceholderBackground: View {
    let thumbhash: String?
    let fallbackSystemName: String?
    let width: CGFloat
    let height: CGFloat

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color(.tertiarySystemFill)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else if let fallbackSystemName {
                Image(systemName: fallbackSystemName)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: width, height: height)
        .task(id: thumbhash) {
            image = nil
            guard let thumbhash else { return }
            let decoded = await ThumbHashImageCache.shared.image(for: thumbhash)
            guard !Task.isCancelled else { return }
            image = decoded
        }
    }
}

/// Drives an `AVAudioSession` `.playback` lease from an externally-controlled
/// `AVPlayer`'s `timeControlStatus`. `VideoPlayer` exposes system transport
/// controls, so the user can pause/resume (and the item can reach its end)
/// without routing through our view code. Observing `timeControlStatus` keeps
/// the lease held only while the player is actually playing and releases it the
/// moment playback pauses or finishes, mirroring how the audio attachment view
/// releases its lease on pause / end-of-playback.
@MainActor
private final class ObservableVideoPlaybackAudioSession {
    private weak var player: AVPlayer?
    private var statusObservation: NSKeyValueObservation?
    private var lease: VoiceAudioSession.Lease?

    /// Begins observing `player`'s play/pause transitions and syncs the lease to
    /// the current status immediately. Safe to call repeatedly; re-attaching to a
    /// new player tears down any prior observation and releases the held lease.
    func attach(to player: AVPlayer) {
        guard self.player !== player else {
            sync(to: player.timeControlStatus)
            return
        }
        stop()
        self.player = player
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] _, _ in
            // Apple does not guarantee KVO callbacks arrive on the main thread,
            // so hop to the MainActor explicitly rather than asserting isolation.
            // Re-read the player's `timeControlStatus` inside the hop from the
            // MainActor-isolated stored reference (avoids capturing the
            // non-Sendable AVPlayer) so the lease converges toward the player's
            // latest state even if hops coalesce or reorder.
            guard let self else { return }
            Task { @MainActor in
                guard let player = self.player else { return }
                self.sync(to: player.timeControlStatus)
            }
        }
    }

    /// Stops observing and releases the audio session lease. Called from the
    /// owning view's teardown points (`onDisappear`, item change, fullscreen
    /// handoff) before the view storage releases this object.
    func stop() {
        statusObservation?.invalidate()
        statusObservation = nil
        player = nil
        release()
    }

    private func sync(to status: AVPlayer.TimeControlStatus) {
        switch VideoPlaybackLeaseAction.resolve(status: status, hasLease: lease != nil) {
        case .acquire:
            lease = try? VoiceAudioSession.configureForVideoPlayback()
        case .release:
            release()
        case .none:
            break
        }
    }

    private func release() {
        VoiceAudioSession.deactivate(lease)
        lease = nil
    }
}

/// Pure decision for how a video playback audio-session lease should respond to
/// an `AVPlayer.timeControlStatus` change. Extracted so the release-on-pause /
/// release-on-end behavior is unit-testable without a live `AVPlayer`.
nonisolated enum VideoPlaybackLeaseAction: Equatable {
    case acquire
    case release
    case none

    static func resolve(status: AVPlayer.TimeControlStatus, hasLease: Bool) -> VideoPlaybackLeaseAction {
        switch status {
        case .playing:
            // Only acquire when we don't already hold a lease, so repeated
            // `.playing` notifications don't stack redundant leases.
            return hasLease ? .none : .acquire
        case .paused:
            // Covers user pause via the system transport control and reaching
            // end-of-item, both of which leave the player in `.paused`. Release
            // only when a lease is actually held.
            return hasLease ? .release : .none
        case .waitingToPlayAtSpecifiedRate:
            // Buffering/stalling while still intending to play; keep the lease.
            return .none
        @unknown default:
            return .none
        }
    }
}

/// Pure decision for whether a received-audio bubble's in-flight load+play task
/// should proceed to start playback after an `await`, or abort. Extracted so the
/// "don't start playback (or acquire the audio-session lease) once the view has
/// disappeared and the task was cancelled" behavior is unit-testable without a
/// live SwiftUI view or `AVAudioPlayer`.
nonisolated enum AudioPlaybackLoadOutcome: Equatable {
    case proceed
    case abort

    static func resolve(isCancelled: Bool) -> AudioPlaybackLoadOutcome {
        isCancelled ? .abort : .proceed
    }
}

private struct MessageVideoAttachmentView: View {
    let item: MessageMediaAttachment
    let isFromMe: Bool
    let width: CGFloat
    let height: CGFloat
    let onLoadMedia: ConversationMediaLoader
    let onOpenFullscreen: (() -> Void)?

    @State private var player: AVPlayer?
    @State private var playbackURL: URL?
    @State private var audioSession = ObservableVideoPlaybackAudioSession()
    @State private var previewThumbnail: UIImage?
    @State private var fullscreenVideo: MessageFullscreenVideo?
    @State private var isLoading = false
    @State private var isLoadingFullscreen = false
    @State private var didFail = false

    @Environment(\.displayScale) private var displayScale

    private var overlayDiameter: CGFloat {
        VideoPreviewOverlayPresentation.diameter(for: CGSize(width: width, height: height))
    }

    private func maxThumbnailPixelSize(scale: CGFloat) -> Int {
        max(1, Int(ceil(max(width, height) * scale)))
    }

    private var thumbnailCacheKey: String {
        MessageVideoThumbnailPresentation.cacheKey(for: item)
    }

    private var displayThumbnail: UIImage? {
        item.thumbnail
            ?? previewThumbnail
            ?? MessageVideoThumbnailDecoder.cachedThumbnail(
                for: thumbnailCacheKey,
                maxPixelSize: maxThumbnailPixelSize(scale: displayScale)
            )
    }

    var body: some View {
        ZStack {
            if let player {
                VideoPlayer(player: player)
                    .frame(width: width, height: height)
                    .background(Color.black)
            } else if let thumbnail = displayThumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                videoPlaceholder
            }

            if player == nil {
                if isLoading {
                    ProgressView()
                        .controlSize(
                            overlayDiameter >= VideoPreviewOverlayPresentation.regularDiameter ? .regular : .small
                        )
                        .tint(.white)
                        .frame(width: overlayDiameter, height: overlayDiameter)
                        .background(Color.black.opacity(0.5), in: Circle())
                } else {
                    VideoPreviewPlayOverlay(
                        systemName: didFail ? "arrow.clockwise" : "play.fill",
                        diameter: overlayDiameter
                    )
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        if let onOpenFullscreen {
                            player?.pause()
                            audioSession.stop()
                            onOpenFullscreen()
                        } else {
                            Task { await openFullscreen(scale: displayScale) }
                        }
                    } label: {
                        Group {
                            if isLoadingFullscreen && onOpenFullscreen == nil {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(.white)
                            } else {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                                    .font(.system(
                                        size: MessageVideoBubblePresentation.fullscreenButtonIconSize,
                                        weight: .bold
                                    ))
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(
                            width: MessageVideoBubblePresentation.fullscreenButtonSize,
                            height: MessageVideoBubblePresentation.fullscreenButtonSize
                        )
                        .background(Color.black.opacity(0.48), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(onOpenFullscreen == nil && isLoadingFullscreen)
                    .accessibilityLabel(
                        onOpenFullscreen == nil
                            ? L10n.string("Open video fullscreen")
                            : L10n.string("Open media gallery")
                    )
                }
                Spacer()
            }
            .padding(MessageVideoBubblePresentation.fullscreenButtonInset)
        }
        .frame(width: width, height: height)
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await loadAndPlay(scale: displayScale) }
        }
        .onChange(of: item.id) { _, _ in
            player?.pause()
            audioSession.stop()
            player = nil
            playbackURL = nil
            previewThumbnail = nil
            fullscreenVideo = nil
            isLoading = false
            isLoadingFullscreen = false
            didFail = false
        }
        .onDisappear {
            player?.pause()
            audioSession.stop()
        }
        .fullScreenCover(item: $fullscreenVideo) { video in
            MessageFullscreenVideoPlayerView(video: video) {
                fullscreenVideo = nil
            }
        }
        .accessibilityLabel("Video attachment")
    }

    private var videoPlaceholder: some View {
        MessageMediaPlaceholderBackground(
            thumbhash: item.reference?.thumbhash,
            fallbackSystemName: "play.rectangle",
            width: width,
            height: height
        )
    }

    private func loadAndPlay(scale: CGFloat) async {
        if let player {
            player.play()
            audioSession.attach(to: player)
            return
        }
        isLoading = true
        didFail = false
        defer { isLoading = false }
        do {
            let url = try await playbackFileURL()
            await loadPreviewThumbnail(from: url, scale: scale)
            let next = AVPlayer(url: url)
            player = next
            next.play()
            audioSession.attach(to: next)
        } catch {
            didFail = true
        }
    }

    private func openFullscreen(scale: CGFloat) async {
        player?.pause()
        audioSession.stop()
        if let playbackURL {
            fullscreenVideo = MessageFullscreenVideo(id: item.id, item: item, url: playbackURL)
            return
        }

        isLoadingFullscreen = true
        didFail = false
        defer { isLoadingFullscreen = false }
        do {
            let url = try await playbackFileURL()
            await loadPreviewThumbnail(from: url, scale: scale)
            fullscreenVideo = MessageFullscreenVideo(id: item.id, item: item, url: url)
        } catch {
            didFail = true
        }
    }

    private func playbackFileURL() async throws -> URL {
        if let playbackURL {
            return playbackURL
        }
        let data = try await onLoadMedia.data(for: item)
        guard let url = await MediaPlaybackFileStore.fileURL(for: item, data: data) else {
            throw MessageVideoAttachmentError.playbackFileUnavailable
        }
        playbackURL = url
        return url
    }

    private func loadPreviewThumbnail(from url: URL, scale: CGFloat) async {
        guard item.thumbnail == nil, previewThumbnail == nil else { return }
        if let cached = MessageVideoThumbnailDecoder.cachedThumbnail(
            for: thumbnailCacheKey,
            maxPixelSize: maxThumbnailPixelSize(scale: scale)
        ) {
            previewThumbnail = cached
            return
        }
        guard let thumbnail = await MessageVideoThumbnailDecoder.thumbnail(
            url: url,
            maxPixelSize: maxThumbnailPixelSize(scale: scale),
            scale: scale
        ) else {
            return
        }
        previewThumbnail = thumbnail
        MessageVideoThumbnailDecoder.store(
            thumbnail,
            for: thumbnailCacheKey,
            maxPixelSize: maxThumbnailPixelSize(scale: scale)
        )
    }
}

private enum MessageVideoAttachmentError: Error {
    case playbackFileUnavailable
}

private struct MessageFullscreenVideoPlayerView: View {
    let video: MessageFullscreenVideo
    let onDismiss: () -> Void

    @State private var player: AVPlayer
    @State private var audioSession = ObservableVideoPlaybackAudioSession()
    @State private var dismissDragOffset: CGFloat = 0

    @ScaledMetric(relativeTo: .body)
    private var closeButtonSize: CGFloat = 42

    init(video: MessageFullscreenVideo, onDismiss: @escaping () -> Void) {
        self.video = video
        self.onDismiss = onDismiss
        _player = State(initialValue: AVPlayer(url: video.url))
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            VideoPlayer(player: player)
                .ignoresSafeArea()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: closeButtonSize, height: closeButtonSize)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .padding(.top, 14)
            .padding(.trailing, 14)
        }
        .offset(y: dismissDragOffset)
        .opacity(1 - min(dismissDragOffset / 420, 0.35))
        .simultaneousGesture(swipeDownToDismissGesture)
        .onAppear {
            player.play()
            audioSession.attach(to: player)
        }
        .onDisappear {
            player.pause()
            audioSession.stop()
        }
    }

    private var swipeDownToDismissGesture: some Gesture {
        DragGesture(minimumDistance: MediaFullscreenDismiss.minimumDistance, coordinateSpace: .local)
            .onChanged { value in
                guard MediaFullscreenDismiss.isDownwardVertical(value.translation) else { return }
                dismissDragOffset = value.translation.height
            }
            .onEnded { value in
                guard dismissDragOffset > 0
                    || MediaFullscreenDismiss.isDownwardVertical(value.translation)
                else { return }

                if dismissDragOffset >= MediaFullscreenDismiss.dismissThreshold
                    || value.predictedEndTranslation.height >= MediaFullscreenDismiss.predictedDismissThreshold
                {
                    onDismiss()
                } else {
                    withAnimation(.snappy(duration: 0.2, extraBounce: 0)) {
                        dismissDragOffset = 0
                    }
                }
            }
    }
}

nonisolated enum MessageAudioPlayerPreparer {
    static func preparedPlayer(from data: Data) async throws -> AVAudioPlayer {
        try await detachedPreparedValue(priority: .userInitiated) { () throws -> AVAudioPlayer in
            let next = try AVAudioPlayer(data: data)
            next.enableRate = true
            next.prepareToPlay()
            return next
        }
    }

    static func duration(from data: Data) async -> Double? {
        await detachedValue(priority: .utility) {
            try? AVAudioPlayer(data: data).duration
        }
    }

    static func detachedPreparedValue<Value>(
        priority: TaskPriority,
        _ operation: @escaping @Sendable () throws -> sending Value
    ) async throws -> sending Value {
        try await Task.detached(priority: priority) {
            try operation()
        }.value
    }

    static func detachedValue<Value: Sendable>(
        priority: TaskPriority,
        _ operation: @escaping @Sendable () -> Value
    ) async -> Value {
        await Task.detached(priority: priority) {
            operation()
        }.value
    }
}

private struct MessageAudioAttachmentView: View {
    let item: MessageMediaAttachment
    let isFromMe: Bool
    let width: CGFloat
    let onLoadMedia: ConversationMediaLoader

    @State private var player: AVAudioPlayer?
    @State private var isLoading = false
    @State private var didFail = false
    @State private var isPlaying = false
    @State private var progress: CGFloat = 0
    @State private var durationSeconds: Double?
    @State private var waveformSamples: [CGFloat]
    @State private var speedIndex = 0
    @State private var progressTask: Task<Void, Never>?
    @State private var playbackLoadTask: Task<Void, Never>?
    @State private var audioSessionLease: VoiceAudioSession.Lease?

    @ScaledMetric(relativeTo: .subheadline)
    private var playButtonSize: CGFloat = 36
    @ScaledMetric(relativeTo: .caption)
    private var speedBadgeWidth: CGFloat = 38
    @ScaledMetric(relativeTo: .caption)
    private var speedBadgeHeight: CGFloat = 28

    private let speeds: [Float] = [1, 1.5, 2]
    private var metadataCacheKey: String {
        MessageAudioBubblePresentation.cacheKey(for: item)
    }

    init(
        item: MessageMediaAttachment,
        isFromMe: Bool,
        width: CGFloat,
        onLoadMedia: ConversationMediaLoader
    ) {
        self.item = item
        self.isFromMe = isFromMe
        self.width = width
        self.onLoadMedia = onLoadMedia
        _durationSeconds = State(initialValue: item.durationSeconds)
        _waveformSamples = State(initialValue: item.waveformSamples.isEmpty ? MediaWaveformAnalyzer.fallback() : item.waveformSamples)
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: togglePlayback) {
                Group {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: isPlaying ? "pause.fill" : didFail ? "arrow.clockwise" : "play.fill")
                            .font(.subheadline.weight(.bold))
                    }
                }
                .frame(width: playButtonSize, height: playButtonSize)
                .foregroundStyle(isFromMe ? Color.accentColor : Color.white)
                .background(isFromMe ? Color.white.opacity(0.95) : Color.accentColor, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? "Pause audio message" : "Play audio message")

            VStack(alignment: .leading, spacing: 5) {
                AudioWaveformView(
                    samples: waveformSamples,
                    progress: progress,
                    barColor: isFromMe ? Color.white.opacity(0.58) : Color.secondary.opacity(0.45),
                    playedColor: isFromMe ? Color.white : Color.accentColor
                )
                .frame(height: 28)
                if let durationLabel = MessageAudioBubblePresentation.durationLabel(durationSeconds ?? item.durationSeconds) {
                    Text(durationLabel)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(isFromMe ? Color.white.opacity(0.75) : Color.secondary)
                }
            }

            Button(action: cycleSpeed) {
                Text(speedLabel)
                    .font(.caption.weight(.bold))
                    .frame(width: speedBadgeWidth, height: speedBadgeHeight)
                    .background(isFromMe ? Color.white.opacity(0.18) : Color.primary.opacity(0.08), in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isFromMe ? Color.white : Color.primary)
            .accessibilityLabel("Playback speed")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: width)
        .frame(minHeight: 68)
        .background(isFromMe ? Color.accentColor : Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.primary.opacity(isFromMe ? 0.12 : 0.08), lineWidth: 1)
        }
        .onDisappear {
            stopPlayback()
        }
        .task(id: metadataCacheKey) {
            await loadMetadataIfNeeded()
        }
    }

    private var speedLabel: String {
        switch speeds[speedIndex] {
        case 1: "1x"
        case 1.5: "1.5x"
        default: "2x"
        }
    }

    private func togglePlayback() {
        if isPlaying {
            pausePlayback()
            return
        }
        if player == nil || didFail {
            // Store the load+play task so it can be cancelled when the view
            // disappears mid-load; cancel any prior in-flight load first so we
            // never stack redundant loads. Mirrors the `progressTask` pattern.
            playbackLoadTask?.cancel()
            playbackLoadTask = Task { await loadAndPlay() }
        } else {
            playLoadedAudio()
        }
    }

    private func cycleSpeed() {
        speedIndex = (speedIndex + 1) % speeds.count
        player?.rate = speeds[speedIndex]
        if isPlaying {
            player?.play()
            player?.rate = speeds[speedIndex]
        }
    }

    private func loadAndPlay() async {
        isLoading = true
        didFail = false
        defer { isLoading = false }
        do {
            let data = try await onLoadMedia.data(for: item)
            // The view may have disappeared (and `stopPlayback` cancelled this
            // task) while the decrypt/download was in flight. Bail before
            // touching player state or acquiring the audio-session lease so a
            // gone view never starts invisible, uncontrollable playback.
            guard AudioPlaybackLoadOutcome.resolve(isCancelled: Task.isCancelled) == .proceed else { return }
            let metadata = await audioMetadata(from: data)
            let next = try await MessageAudioPlayerPreparer.preparedPlayer(from: data)
            guard AudioPlaybackLoadOutcome.resolve(isCancelled: Task.isCancelled) == .proceed else { return }
            player = next
            let playableMetadata = MessageAudioMetadata(
                durationSeconds: metadata.durationSeconds ?? next.duration,
                samples: metadata.samples
            )
            MessageAudioMetadataCache.store(playableMetadata, for: metadataCacheKey)
            applyMetadata(playableMetadata)
            playLoadedAudio()
        } catch {
            // A cancelled load is an expected disappearance, not a failure;
            // don't flip the bubble into the retry/failed state for it.
            if Task.isCancelled { return }
            didFail = true
            isPlaying = false
        }
    }

    private func loadMetadataIfNeeded() async {
        if let cached = MessageAudioMetadataCache.metadata(for: metadataCacheKey) {
            applyMetadata(cached)
            return
        }

        if let embedded = embeddedMetadata {
            MessageAudioMetadataCache.store(embedded, for: metadataCacheKey)
            applyMetadata(embedded)
        }
    }

    private var embeddedMetadata: MessageAudioMetadata? {
        guard item.durationSeconds != nil, !item.waveformSamples.isEmpty else {
            return nil
        }
        return MessageAudioMetadata(
            durationSeconds: item.durationSeconds,
            samples: MediaWaveformAnalyzer.normalized(item.waveformSamples)
        )
    }

    private func audioMetadata(from data: Data) async -> MessageAudioMetadata {
        if let cached = MessageAudioMetadataCache.metadata(for: metadataCacheKey) {
            return cached
        }

        let analyzed = await Task.detached(priority: .utility) {
            MediaWaveformAnalyzer.metadata(from: data, mediaType: item.mediaType)
        }.value
        let duration: Double?
        if let analyzedDuration = analyzed.durationSeconds {
            duration = analyzedDuration
        } else {
            duration = await MessageAudioPlayerPreparer.duration(from: data)
        }
        let metadata = MessageAudioMetadata(
            durationSeconds: duration,
            samples: MediaWaveformAnalyzer.normalized(analyzed.samples)
        )
        MessageAudioMetadataCache.store(metadata, for: metadataCacheKey)
        return metadata
    }

    private func applyMetadata(_ metadata: MessageAudioMetadata) {
        durationSeconds = metadata.durationSeconds
        waveformSamples = MediaWaveformAnalyzer.normalized(metadata.samples)
    }

    private func playLoadedAudio() {
        guard let player else { return }
        do {
            releaseAudioSession()
            audioSessionLease = try VoiceAudioSession.configureForPlayback()
        } catch {
            failPlaybackStart()
            return
        }
        if player.currentTime >= player.duration {
            player.currentTime = 0
        }
        player.enableRate = true
        player.rate = speeds[speedIndex]
        guard player.play() else {
            failPlaybackStart()
            return
        }
        player.rate = speeds[speedIndex]
        didFail = false
        isPlaying = true
        startProgressLoop()
    }

    private func pausePlayback() {
        progressTask?.cancel()
        progressTask = nil
        player?.pause()
        isPlaying = false
        releaseAudioSession()
    }

    private func failPlaybackStart() {
        progressTask?.cancel()
        progressTask = nil
        releaseAudioSession()
        didFail = true
        isPlaying = false
    }

    private func startProgressLoop() {
        progressTask?.cancel()
        progressTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                guard let player else { return }
                let duration = max(0.01, player.duration)
                progress = min(1, max(0, CGFloat(player.currentTime / duration)))
                if !player.isPlaying {
                    finishPlayback()
                    if progress >= 0.995 {
                        progress = 0
                        player.currentTime = 0
                    }
                    return
                }
            }
        }
    }

    private func finishPlayback() {
        progressTask?.cancel()
        progressTask = nil
        isPlaying = false
        releaseAudioSession()
    }

    private func stopPlayback() {
        progressTask?.cancel()
        progressTask = nil
        // Cancel any in-flight load+play task. Without this, a load resolving
        // after the view disappeared would start playback (and acquire the
        // `.playback` lease) on a view that is no longer on screen.
        playbackLoadTask?.cancel()
        playbackLoadTask = nil
        let shouldDeactivate = isPlaying || player?.isPlaying == true || audioSessionLease != nil
        player?.stop()
        isPlaying = false
        if shouldDeactivate {
            releaseAudioSession()
        }
    }

    private func releaseAudioSession() {
        VoiceAudioSession.deactivate(audioSessionLease)
        audioSessionLease = nil
    }

}

private struct MessageAudioMetadata: Sendable {
    let durationSeconds: Double?
    let samples: [CGFloat]
}

private enum MessageAudioMetadataCache {
    private final class CachedMetadata: NSObject {
        let durationSeconds: Double?
        let samples: [CGFloat]

        init(_ metadata: MessageAudioMetadata) {
            durationSeconds = metadata.durationSeconds
            samples = metadata.samples
        }

        var metadata: MessageAudioMetadata {
            MessageAudioMetadata(durationSeconds: durationSeconds, samples: samples)
        }
    }

    private static let cache: NSCache<NSString, CachedMetadata> = {
        let cache = NSCache<NSString, CachedMetadata>()
        cache.countLimit = 200
        return cache
    }()

    static func metadata(for key: String) -> MessageAudioMetadata? {
        cache.object(forKey: key as NSString)?.metadata
    }

    static func store(_ metadata: MessageAudioMetadata, for key: String) {
        cache.setObject(CachedMetadata(metadata), forKey: key as NSString)
    }
}

private struct MessageDocumentAttachmentView: View {
    let item: MessageMediaAttachment
    let isFromMe: Bool
    let width: CGFloat
    let onLoadMedia: ConversationMediaLoader

    @State private var isLoading = false
    @State private var didFail = false
    @State private var shareItem: MessageDocumentShareItem?

    @ScaledMetric(relativeTo: .title2)
    private var iconTileSize: CGFloat = 38

    var body: some View {
        Button {
            Task { await openDocument() }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: item.kind.systemImageName)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(isFromMe ? Color.white : Color.accentColor)
                    .frame(width: iconTileSize, height: iconTileSize)
                    .background(isFromMe ? Color.white.opacity(0.15) : Color.accentColor.opacity(0.10), in: .rect(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.fileName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(fileDetail)
                        .font(.caption2)
                        .foregroundStyle(isFromMe ? Color.white.opacity(0.74) : Color.secondary)
                }
                Spacer(minLength: 0)
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(isFromMe ? .white : .accentColor)
                } else if didFail {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                }
            }
            .foregroundStyle(isFromMe ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(width: width)
            .frame(minHeight: 66)
            .background(isFromMe ? Color.accentColor : Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Color.primary.opacity(isFromMe ? 0.12 : 0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open attachment")
        .sheet(item: $shareItem) { shareItem in
            MessageDocumentShareSheet(url: shareItem.url)
        }
    }

    private var fileDetail: String {
        MediaAttachmentPolicy.canonicalMediaType(item.mediaType)
    }

    private func openDocument() async {
        isLoading = true
        didFail = false
        defer { isLoading = false }
        do {
            let data = try await onLoadMedia.data(for: item)
            guard let url = await MediaPlaybackFileStore.fileURL(for: item, data: data) else {
                didFail = true
                return
            }
            shareItem = MessageDocumentShareItem(url: url)
        } catch {
            didFail = true
        }
    }
}

private struct MessageDocumentShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

private struct MessageDocumentShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

enum MessageVideoThumbnailDecoder {
    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 50 * 1024 * 1024
        return cache
    }()

    static func cachedThumbnail(for itemID: String, maxPixelSize: Int) -> UIImage? {
        cache.object(forKey: cacheKey(for: itemID, maxPixelSize: maxPixelSize))
    }

    static func store(_ image: UIImage, for itemID: String, maxPixelSize: Int) {
        let pixelCost = max(1, Int(image.size.width * image.scale * image.size.height * image.scale * 4))
        cache.setObject(
            image,
            forKey: cacheKey(for: itemID, maxPixelSize: maxPixelSize),
            cost: pixelCost
        )
    }

    static func thumbnail(url: URL, maxPixelSize: Int, scale: CGFloat) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let boundedSize = max(1, maxPixelSize)
        let imageScale = max(1, scale)
        return await withCheckedContinuation { continuation in
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: boundedSize, height: boundedSize)
            generator.generateCGImageAsynchronously(for: .zero) { image, _, error in
                guard let image, error == nil else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: UIImage(cgImage: image, scale: imageScale, orientation: .up))
            }
        }
    }

    private static func cacheKey(for itemID: String, maxPixelSize: Int) -> NSString {
        "\(itemID):\(max(1, maxPixelSize))" as NSString
    }
}

enum MessageMediaThumbnailDecoder {
    private final class CachedThumbnail: NSObject {
        let image: UIImage
        let sourceData: Data

        init(image: UIImage, sourceData: Data) {
            self.image = image
            self.sourceData = sourceData
        }
    }

    private static let cache: NSCache<NSString, CachedThumbnail> = {
        let cache = NSCache<NSString, CachedThumbnail>()
        cache.totalCostLimit = 50 * 1024 * 1024
        return cache
    }()

    static func cachedThumbnail(for itemID: String, maxPixelSize: Int) -> (image: UIImage, sourceData: Data)? {
        guard let cached = cache.object(forKey: cacheKey(for: itemID, maxPixelSize: maxPixelSize)) else {
            return nil
        }
        return (cached.image, cached.sourceData)
    }

    static func store(_ image: UIImage, sourceData: Data, for itemID: String, maxPixelSize: Int) {
        cache.setObject(
            CachedThumbnail(image: image, sourceData: sourceData),
            forKey: cacheKey(for: itemID, maxPixelSize: maxPixelSize),
            cost: thumbnailCacheCost(for: image, sourceData: sourceData)
        )
    }

    static func thumbnailCacheCost(for image: UIImage, sourceData: Data) -> Int {
        let bitmapCost = DecodedImageCost.decodedBitmapByteCost(for: image)
        guard Int.max - bitmapCost >= sourceData.count else { return Int.max }
        return max(1, bitmapCost + sourceData.count)
    }

    static func image(data: Data, maxPixelSize: Int, scale: CGFloat) async -> UIImage? {
        let targetPixelSize = max(1, maxPixelSize)
        let imageScale = max(1, scale)
        return await Task.detached(priority: .utility) { () -> UIImage? in
            decodeThumbnailImage(
                data: data,
                targetPixelSize: targetPixelSize,
                imageScale: imageScale,
                createSource: { data, options in
                    CGImageSourceCreateWithData(data as CFData, options)
                },
                createThumbnail: { source, options in
                    CGImageSourceCreateThumbnailAtIndex(source, 0, options)
                }
            )
        }.value
    }

    nonisolated static func decodeThumbnailImage(
        data: Data,
        targetPixelSize: Int,
        imageScale: CGFloat,
        createSource: (Data, CFDictionary) -> CGImageSource?,
        sourceType: (CGImageSource) -> CFString? = { CGImageSourceGetType($0) },
        createThumbnail: (CGImageSource, CFDictionary) -> CGImage?
    ) -> UIImage? {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]
        guard let source = createSource(data, sourceOptions as CFDictionary) else {
            return nil
        }
        // Peer-controlled MLS media attachments are admitted here purely on a
        // `image/*` MIME prefix, which includes `image/svg+xml`. Gate the actual
        // decoded container type through the shared remote-image allowlist so SVG
        // (and any non-image container ImageIO would otherwise parse) is rejected
        // before thumbnailing, mirroring the HTTP avatar/group-image path.
        guard RemoteImageDecoder.isAllowedRemoteImageType(sourceType(source)) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, targetPixelSize),
        ]
        guard let cgImage = createThumbnail(source, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: cgImage, scale: max(1, imageScale), orientation: .up)
    }

    private static func cacheKey(for itemID: String, maxPixelSize: Int) -> NSString {
        "\(itemID):\(maxPixelSize)" as NSString
    }
}

struct MessageMediaGallery: Identifiable {
    let id = UUID()
    let items: [MessageMediaAttachment]
    let initialItemID: String
    let initialMediaData: Data?

    init?(item: MessageMediaAttachment, imageData: Data) {
        self.init(items: [item], initialItem: item, initialMediaData: imageData)
    }

    init?(items: [MessageMediaAttachment], initialItem: MessageMediaAttachment, initialImageData: Data) {
        self.init(items: items, initialItem: initialItem, initialMediaData: initialImageData)
    }

    init?(items: [MessageMediaAttachment], initialItem: MessageMediaAttachment, initialMediaData: Data? = nil) {
        guard initialItem.isImage || initialItem.isVideo else { return nil }
        let visualItems = items.filter { $0.isImage || $0.isVideo }
        if visualItems.contains(where: { $0.id == initialItem.id }) {
            self.items = visualItems
        } else {
            self.items = [initialItem] + visualItems
        }
        self.initialItemID = initialItem.id
        self.initialMediaData = initialMediaData
    }

    func initialData(for item: MessageMediaAttachment) -> Data? {
        if item.id == initialItemID {
            return initialMediaData
        }
        return item.localData
    }
}

enum MessageMediaFullscreenPresentation {
    /// Pixel budget for a fullscreen decode derived from the longest native
    /// screen edge. The fullscreen view only ever renders the image
    /// `scaledToFit` within the screen, so a screen-sized decode is visually
    /// lossless for presentation while capping the worst-case bitmap
    /// allocation. Pure helper kept separate from `UIScreen` so it stays
    /// testable and free of MainActor isolation.
    static func fullscreenMaxPixelSize(forLongestScreenEdge longestEdge: CGFloat) -> Int {
        guard longestEdge.isFinite, longestEdge >= 1 else { return 1 }
        return max(1, Int(longestEdge.rounded(.up)))
    }

    /// Decodes attacker-controlled image bytes off the MainActor, bounded to a
    /// screen-sized pixel budget. Mirrors the thumbnail/grid hardening
    /// (`MessageMediaThumbnailDecoder`) so the fullscreen path never performs a
    /// full-resolution decode on the MainActor, and a crafted high-megapixel
    /// image cannot allocate an unbounded bitmap on the UI actor.
    static func decodedImage(from data: Data?, maxPixelSize: Int, scale: CGFloat) async -> UIImage? {
        guard let data else { return nil }
        return await MessageMediaThumbnailDecoder.image(
            data: data,
            maxPixelSize: maxPixelSize,
            scale: scale
        )
    }
}

private enum MediaFullscreenDismiss {
    static let minimumDistance: CGFloat = 16
    static let dismissThreshold: CGFloat = 120
    static let predictedDismissThreshold: CGFloat = 240
    static let verticalDominance: CGFloat = 1.2

    static func isDownwardVertical(_ translation: CGSize) -> Bool {
        translation.height > 0
            && translation.height > abs(translation.width) * verticalDominance
    }
}

nonisolated enum MessageMediaFullscreenGalleryPresentation {
    static func pageCountLabel(
        selectedIndex: Int?,
        totalCount: Int,
        locale: Locale = AppLanguage.currentLocale
    ) -> String {
        guard let selectedIndex,
              selectedIndex >= 0,
              totalCount > 0
        else { return "" }
        let current = LocalizedNumberLabel.decimal(UInt64(selectedIndex + 1), locale: locale)
        let total = LocalizedNumberLabel.decimal(UInt64(totalCount), locale: locale)
        return L10n.formatted("%@ of %@", arguments: [current, total], locale: locale)
    }
}

struct MessageMediaFullscreenGalleryView: View {
    let gallery: MessageMediaGallery
    let onLoadMedia: ConversationMediaLoader
    let onDismiss: () -> Void

    @State private var selectedItemID: String
    @State private var dismissDragOffset: CGFloat = 0

    @ScaledMetric(relativeTo: .body)
    private var closeButtonSize: CGFloat = 42

    init(
        gallery: MessageMediaGallery,
        onLoadMedia: ConversationMediaLoader,
        onDismiss: @escaping () -> Void
    ) {
        self.gallery = gallery
        self.onLoadMedia = onLoadMedia
        self.onDismiss = onDismiss
        _selectedItemID = State(initialValue: gallery.initialItemID)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            TabView(selection: $selectedItemID) {
                ForEach(gallery.items) { item in
                    MessageMediaFullscreenPage(
                        item: item,
                        isSelected: item.id == selectedItemID,
                        initialImageData: gallery.initialData(for: item),
                        onLoadMedia: onLoadMedia
                    )
                    .tag(item.id)
                }
            }
            .tabViewStyle(
                .page(indexDisplayMode: .never)
            )
            .ignoresSafeArea()

            if gallery.items.count > 1 {
                Text(pageCountLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 34)
            }

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.body.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: closeButtonSize, height: closeButtonSize)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
            .padding(.top, 14)
            .padding(.trailing, 14)
        }
        .offset(y: dismissDragOffset)
        .opacity(1 - min(dismissDragOffset / 420, 0.35))
        .simultaneousGesture(swipeDownToDismissGesture)
    }

    private var swipeDownToDismissGesture: some Gesture {
        DragGesture(minimumDistance: MediaFullscreenDismiss.minimumDistance, coordinateSpace: .local)
            .onChanged { value in
                guard MediaFullscreenDismiss.isDownwardVertical(value.translation) else { return }
                dismissDragOffset = value.translation.height
            }
            .onEnded { value in
                guard dismissDragOffset > 0
                    || MediaFullscreenDismiss.isDownwardVertical(value.translation)
                else { return }

                if dismissDragOffset >= MediaFullscreenDismiss.dismissThreshold
                    || value.predictedEndTranslation.height >= MediaFullscreenDismiss.predictedDismissThreshold
                {
                    onDismiss()
                } else {
                    withAnimation(.snappy(duration: 0.2, extraBounce: 0)) {
                        dismissDragOffset = 0
                    }
                }
            }
    }

    private var pageCountLabel: String {
        MessageMediaFullscreenGalleryPresentation.pageCountLabel(
            selectedIndex: gallery.items.firstIndex(where: { $0.id == selectedItemID }),
            totalCount: gallery.items.count
        )
    }
}

private struct MessageMediaFullscreenPage: View {
    let item: MessageMediaAttachment
    let isSelected: Bool
    let initialImageData: Data?
    let onLoadMedia: ConversationMediaLoader

    var body: some View {
        if item.isVideo {
            MessageMediaFullscreenVideoPage(
                item: item,
                isSelected: isSelected,
                onLoadMedia: onLoadMedia
            )
        } else {
            MessageMediaFullscreenImagePage(
                item: item,
                initialImageData: initialImageData,
                onLoadMedia: onLoadMedia
            )
        }
    }
}

private struct MessageMediaFullscreenVideoPage: View {
    let item: MessageMediaAttachment
    let isSelected: Bool
    let onLoadMedia: ConversationMediaLoader

    @State private var player: AVPlayer?
    @State private var playbackURL: URL?
    @State private var audioSession = ObservableVideoPlaybackAudioSession()
    @State private var isLoading = false
    @State private var didFail = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if let thumbnail = item.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if isLoading {
                ProgressView()
                    .tint(.white)
                    .controlSize(.regular)
            } else if didFail {
                Button {
                    Task { await loadAndPlay(force: true) }
                } label: {
                    Label(L10n.string("Retry"), systemImage: "arrow.clockwise")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
            } else if player == nil {
                Button {
                    Task { await loadAndPlay() }
                } label: {
                    VideoPreviewPlayOverlay(
                        diameter: VideoPreviewOverlayPresentation.maximumDiameter
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.string("Play video"))
            }
        }
        .contentShape(Rectangle())
        .onAppear {
            startPlaybackIfSelected()
        }
        .onChange(of: isSelected) { _, selected in
            if selected {
                startPlaybackIfSelected()
            } else {
                releasePlayback()
            }
        }
        .onDisappear {
            releasePlayback()
        }
        .accessibilityLabel(L10n.string("Video attachment"))
    }

    private func startPlaybackIfSelected() {
        guard isSelected else { return }
        Task { await loadAndPlay() }
    }

    private func loadAndPlay(force: Bool = false) async {
        guard isSelected else { return }
        guard force || !isLoading else { return }
        if force {
            // Retry should refetch the decrypted playback file, while ordinary
            // re-selection reuses the memoized URL after releasing the player.
            releasePlayback()
            playbackURL = nil
        } else if let player {
            player.play()
            audioSession.attach(to: player)
            return
        }

        isLoading = true
        didFail = false
        defer { isLoading = false }
        do {
            let url = try await playbackFileURL()
            guard !Task.isCancelled, isSelected else { return }
            let next = AVPlayer(url: url)
            player = next
            next.play()
            audioSession.attach(to: next)
        } catch {
            guard !Task.isCancelled, isSelected else { return }
            didFail = true
        }
    }

    private func playbackFileURL() async throws -> URL {
        if let playbackURL {
            return playbackURL
        }
        let data = try await onLoadMedia.data(for: item)
        guard let url = await MediaPlaybackFileStore.fileURL(for: item, data: data) else {
            throw MessageVideoAttachmentError.playbackFileUnavailable
        }
        playbackURL = url
        return url
    }

    private func releasePlayback() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        audioSession.stop()
        player = nil
    }
}

private struct MessageMediaFullscreenImagePage: View {
    let item: MessageMediaAttachment
    let onLoadMedia: ConversationMediaLoader

    @State private var imageData: Data?
    @State private var image: UIImage?
    @State private var isLoading = false
    @State private var didFail = false

    @Environment(\.displayScale) private var displayScale

    init(
        item: MessageMediaAttachment,
        initialImageData: Data?,
        onLoadMedia: ConversationMediaLoader
    ) {
        self.item = item
        self.onLoadMedia = onLoadMedia
        // Do NOT decode here. Decoding attacker-controlled bytes is deferred to
        // `loadImageIfNeeded`, which runs the decode off the MainActor and
        // bounded to a screen-sized pixel budget. Stash the raw initial bytes
        // (if any) so the first load can reuse them without re-fetching.
        _imageData = State(initialValue: initialImageData)
    }

    private func fullscreenMaxPixelSize(viewSize: CGSize, scale: CGFloat) -> Int {
        let longestPoint = max(viewSize.width, viewSize.height)
        let longestEdge = max(1, longestPoint * scale)
        return MessageMediaFullscreenPresentation.fullscreenMaxPixelSize(forLongestScreenEdge: longestEdge)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if isLoading {
                    ProgressView()
                        .tint(.white)
                } else if didFail {
                    Button {
                        Task { await loadImageIfNeeded(viewSize: proxy.size, scale: displayScale, force: true) }
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(.ultraThinMaterial, in: Capsule())
                    }
                    .buttonStyle(.plain)
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: item.id) {
                await loadImageIfNeeded(viewSize: proxy.size, scale: displayScale)
            }
        }
    }

    private func loadImageIfNeeded(viewSize: CGSize, scale: CGFloat, force: Bool = false) async {
        guard image == nil || force else { return }
        let maxPixelSize = fullscreenMaxPixelSize(viewSize: viewSize, scale: scale)

        // First, try decoding any bytes we already hold (initial data passed in
        // from the gallery / a previous load) off the MainActor before paying
        // for another fetch.
        if !force, let existing = imageData {
            if let decoded = await MessageMediaFullscreenPresentation.decodedImage(
                from: existing,
                maxPixelSize: maxPixelSize,
                scale: scale
            ) {
                guard !Task.isCancelled else { return }
                image = decoded
                didFail = false
                return
            }
        }

        isLoading = true
        didFail = false
        defer { isLoading = false }
        do {
            let data = try await onLoadMedia.data(for: item)
            guard !Task.isCancelled else { return }
            guard let decoded = await MessageMediaFullscreenPresentation.decodedImage(
                from: data,
                maxPixelSize: maxPixelSize,
                scale: scale
            ) else {
                guard !Task.isCancelled else { return }
                imageData = nil
                image = nil
                didFail = true
                return
            }
            guard !Task.isCancelled else { return }
            imageData = data
            image = decoded
        } catch {
            guard !Task.isCancelled else { return }
            imageData = nil
            image = nil
            didFail = true
        }
    }
}
