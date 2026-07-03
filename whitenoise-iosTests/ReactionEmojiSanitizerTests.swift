import Testing
@testable import whitenoise_ios

/// #70 — reaction "emoji" come from peers and must be sanitized before display,
/// without breaking legitimate multi-scalar emoji.
struct ReactionEmojiSanitizerTests {

    @Test func passesPlainEmojiThrough() {
        #expect(ContentSanitizer.reactionEmoji("👍") == "👍")
    }

    @Test func stripsBidiAndZeroWidthCharacters() {
        #expect(ContentSanitizer.reactionEmoji("\u{202E}👍\u{200B}") == "👍")
        #expect(ContentSanitizer.reactionEmoji("  👎\n") == "👎")
    }

    @Test func preservesZWJAndVariationSelectorSequences() {
        #expect(ContentSanitizer.reactionEmoji("👨‍👩‍👧") == "👨‍👩‍👧") // ZWJ family
        #expect(ContentSanitizer.reactionEmoji("❤️") == "❤️")           // U+FE0F variation selector
    }

    @Test func capsAbusivelyLongReactions() {
        let long = String(repeating: "🎉", count: 50)
        let sanitized = ContentSanitizer.reactionEmoji(long)

        #expect(sanitized == String(repeating: "🎉", count: ContentSanitizer.maxReactionLength))
        #expect(!sanitized.isEmpty)
    }
}
