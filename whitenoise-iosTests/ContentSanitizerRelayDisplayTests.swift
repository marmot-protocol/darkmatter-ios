import Testing
@testable import whitenoise_ios

struct ContentSanitizerRelayDisplayTests {

    @Test func stripsZeroWidthNonJoinerJoinerAndWordJoiner() {
        let spoofed = "wss://re\u{200C}lay\u{200D}evil\u{2060}.example"
        let display = ContentSanitizer.relayDisplayLine(spoofed, maxLength: 120)
        #expect(display == "wss://relayevil.example")
    }

    @Test func stripsTheFullInvisibleFormatFamily() {
        let spoofed = "wss://x"
            + "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}"
            + "\u{2066}\u{2067}\u{2068}\u{2069}\u{061C}\u{200B}\u{FEFF}"
            + "\u{200C}\u{200D}\u{2060}"
            + ".example"
        #expect(ContentSanitizer.relayDisplayLine(spoofed, maxLength: 120) == "wss://x.example")
    }

    @Test func collapsesWhitespaceLikeSingleLine() {
        let display = ContentSanitizer.relayDisplayLine("  wss://relay\t\n  spaced.example  ", maxLength: 120)
        #expect(display == "wss://relay spaced.example")
    }

    @Test func cleanRelayPassesThroughUnchanged() {
        #expect(ContentSanitizer.relayDisplayLine("wss://relay.example", maxLength: 120) == "wss://relay.example")
    }

    @Test func emptyOrFormatOnlyReturnsNil() {
        #expect(ContentSanitizer.relayDisplayLine(nil, maxLength: 120) == nil)
        #expect(ContentSanitizer.relayDisplayLine("   ", maxLength: 120) == nil)
        #expect(ContentSanitizer.relayDisplayLine("\u{200C}\u{200D}\u{2060}\u{FEFF}", maxLength: 120) == nil)
    }

    @Test func capsLength() {
        let long = "wss://" + String(repeating: "a", count: 200) + ".example"
        let display = ContentSanitizer.relayDisplayLine(long, maxLength: 120)
        #expect((display?.count ?? 0) <= 120)
    }

    @Test func reactionEmojiStillPreservesZWJSequences() {
        #expect(ContentSanitizer.reactionEmoji("👨‍👩‍👧") == "👨‍👩‍👧") // ZWJ family
        #expect(ContentSanitizer.reactionEmoji("❤️") == "❤️")           // U+FE0F variation selector
    }

    @Test func singleLineStillPreservesFormatCharacters() {
        let withZWJ = "a\u{200D}b"
        #expect(ContentSanitizer.singleLine(withZWJ, maxLength: 80) == withZWJ)
    }
}
