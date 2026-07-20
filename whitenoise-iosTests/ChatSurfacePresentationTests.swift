import CoreGraphics
import Foundation
import Testing
@testable import whitenoise_ios

@MainActor
struct ChatSurfacePresentationTests {
    @Test func deliveryFooterUsesCompactSymbols() {
        #expect(MessageFooterPresentation.value(for: .sent, isFromMe: true).systemImage == "checkmark")
        #expect(MessageFooterPresentation.value(for: .sending, isFromMe: true).systemImage == "clock")
        #expect(MessageFooterPresentation.value(for: .failed, isFromMe: true).isFailure)
        #expect(MessageFooterPresentation.value(for: .received, isFromMe: false).systemImage == nil)
    }

    @Test func mediaUploadIndicatorOnlyAppearsForPendingLocalMedia() {
        let pending = MessageMediaAttachment(
            id: "pending-image",
            reference: nil,
            fileName: "photo.jpg",
            mediaType: "image/jpeg",
            dim: "640x480",
            localData: Data([1])
        )
        let unresolvedRemote = MessageMediaAttachment(
            id: "remote-image",
            reference: nil,
            fileName: "photo.jpg",
            mediaType: "image/jpeg",
            dim: "640x480",
            localData: nil
        )

        #expect(MessageMediaUploadPresentation.showsIndicator(status: .sending, items: [pending]))
        #expect(!MessageMediaUploadPresentation.showsIndicator(status: .sent, items: [pending]))
        #expect(!MessageMediaUploadPresentation.showsIndicator(status: .failed, items: [pending]))
        #expect(!MessageMediaUploadPresentation.showsIndicator(status: .sending, items: [unresolvedRemote]))
        #expect(!MessageMediaUploadPresentation.showsIndicator(status: .sending, items: []))
    }

    @Test func reactionSummaryCombinesEmojisAndTotalCount() throws {
        let summary = try #require(ReactionSummaryPresentation.value(from: [
            .init(emoji: "👍", count: 4, mine: false),
            .init(emoji: "❤️", count: 3, mine: true),
            .init(emoji: "😂", count: 2, mine: false),
            .init(emoji: "😮", count: 1, mine: false),
        ]))

        #expect(summary.emojis == ["❤️", "👍", "😂"])
        #expect(summary.totalCount == 10)
        #expect(summary.mine)
        #expect(ReactionSummaryPresentation.value(from: []) == nil)
    }

    @Test func emojiSearchPrefersExactAndPrefixNames() {
        let entries = [
            EmojiCatalogEntry(emoji: "😂", name: "face with tears of joy", group: 0, keywords: ["laugh"]),
            EmojiCatalogEntry(emoji: "😊", name: "smiling face", group: 0, keywords: ["happy"]),
            EmojiCatalogEntry(emoji: "❤️", name: "red heart", group: 7, keywords: ["love"]),
        ]

        #expect(EmojiCatalogSearch.results(in: entries, query: "smiling").map(\.emoji) == ["😊"])
        #expect(EmojiCatalogSearch.results(in: entries, query: "love").map(\.emoji) == ["❤️"])
        #expect(EmojiCatalogSearch.results(in: entries, query: "face joy").map(\.emoji) == ["😂"])
    }

    @Test func emojiCatalogDecodingPrecomputesCaseInsensitiveSearchTerms() throws {
        let data = Data(#"[{"e":"x","n":"Smiling FACE","g":0,"k":["HAPPY","Joy"]}]"#.utf8)
        let entry = try #require(JSONDecoder().decode([EmojiCatalogEntry].self, from: data).first)

        #expect(entry.nameLowercased == "smiling face")
        #expect(entry.keywordsLowercased == ["happy", "joy"])
        #expect(EmojiCatalogSearch.results(in: [entry], query: "FACE joy") == [entry])
    }

    @Test func timelineDaySectionsReuseGenerationAndInvalidateForCalendarContext() {
        let cache = ConversationDaySectionProjectionCache()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "en_US")
        let items = [
            TimelineItem.systemEvent(id: "1", event: .groupCreated, timestamp: 86_400),
            TimelineItem.systemEvent(id: "2", event: .rosterChanged, timestamp: 86_401),
            TimelineItem.systemEvent(id: "3", event: .groupArchived, timestamp: 172_800),
        ]

        let first = cache.sections(for: items, generation: 1, calendar: calendar, locale: locale)
        let cached = cache.sections(for: items, generation: 1, calendar: calendar, locale: locale)
        #expect(first == cached)
        #expect(first.map(\.items.count) == [2, 1])
        #expect(cache.buildCountForTesting == 1)

        calendar.timeZone = TimeZone(secondsFromGMT: 3_600)!
        _ = cache.sections(for: items, generation: 1, calendar: calendar, locale: locale)
        _ = cache.sections(
            for: items,
            generation: 1,
            calendar: calendar,
            locale: Locale(identifier: "fr_FR")
        )
        _ = cache.sections(for: items, generation: 2, calendar: calendar, locale: locale)
        #expect(cache.buildCountForTesting == 4)
    }

    @Test func mediaGridHandlesOneThroughOverflowWithoutMoreThanFiveTiles() {
        for count in 1...8 {
            let visible = MessageMediaGridPresentation.visibleCount(totalCount: count)
            let columns = MessageMediaGridPresentation.columnCount(totalCount: count)
            let rows = MessageMediaGridPresentation.rowCount(totalCount: count)
            #expect(visible <= 5)
            #expect(rows * columns >= visible)
            #expect(MessageMediaGridPresentation.hiddenCount(totalCount: count) == max(0, count - 5))
        }
    }

    @Test func compactBubblesReserveReadableOppositeMargin() {
        #expect(ChatBubbleMetrics.compactOppositeInset >= 44)
        #expect(ChatBubbleMetrics.regularMaximumWidth == 560)
    }

    @Test func allVisibleMessageBodiesPlaceMetadataOnTheirLastLine() {
        #expect(MessageBubbleTextLayout.usesInlineFooter(text: "Short", isCollapsed: false))
        #expect(MessageBubbleTextLayout.usesInlineFooter(
            text: "This is a longer message that should wrap naturally",
            isCollapsed: false
        ))
        #expect(MessageBubbleTextLayout.usesInlineFooter(text: "First\nSecond", isCollapsed: false))
        #expect(!MessageBubbleTextLayout.usesInlineFooter(text: "Collapsed", isCollapsed: true))
    }

    @Test func multiMessageSelectionUsesSharedForwardLimitAndStrictDeleteCapability() {
        #expect(MessageSelectionPolicy.canForward(selectedCount: 1, allForwardable: true))
        #expect(MessageSelectionPolicy.canForward(selectedCount: 30, allForwardable: true))
        #expect(!MessageSelectionPolicy.canForward(selectedCount: 31, allForwardable: true))
        #expect(!MessageSelectionPolicy.canForward(selectedCount: 2, allForwardable: false))
        #expect(MessageSelectionPolicy.canDelete(selectedCount: 2, allDeletable: true))
        #expect(!MessageSelectionPolicy.canDelete(selectedCount: 2, allDeletable: false))
    }

    @Test func conversationDateHeadersCategorizeTodayYesterdayAndOlderDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1_721_174_400)
        let today = UInt64(now.timeIntervalSince1970)
        let yesterday = UInt64(calendar.date(byAdding: .day, value: -1, to: now)!.timeIntervalSince1970)
        let older = UInt64(calendar.date(byAdding: .day, value: -4, to: now)!.timeIntervalSince1970)

        #expect(ConversationDateHeader.label(timestamp: today, now: now, calendar: calendar) == "Today")
        #expect(ConversationDateHeader.label(timestamp: yesterday, now: now, calendar: calendar) == "Yesterday")
        #expect(ConversationDateHeader.label(timestamp: older, now: now, calendar: calendar) != "Today")
        #expect(ConversationDateHeader.label(timestamp: older, now: now, calendar: calendar) != "Yesterday")
    }

    @Test func composerShowsExpandedEditorForLongOrMultilineDrafts() {
        #expect(!ComposerExpandedEditorPresentation.shouldShowExpandButton(for: "Short"))
        #expect(ComposerExpandedEditorPresentation.shouldShowExpandButton(
            for: String(repeating: "a", count: ComposerExpandedEditorPresentation.minimumExpandCharacterCount)
        ))
        #expect(ComposerExpandedEditorPresentation.shouldShowExpandButton(for: "one\ntwo\nthree\nfour"))
    }

    @Test func sharedLocationUsesStableMapURLCoordinates() {
        #expect(
            SharedLocationText.value(latitude: 9.0765, longitude: 7.3986)
                == "https://maps.apple.com/?ll=9.076500,7.398600"
        )
    }
}
