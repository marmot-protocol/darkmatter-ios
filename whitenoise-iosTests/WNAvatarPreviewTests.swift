import Testing
@testable import whitenoise_ios

struct WNAvatarPreviewTests {
    @Test func theLargeAvatarShowsOneLetterEvenForAMultiWordName() {
        // AvatarBubble's two-letter monogram is a row treatment; the header
        // avatar takes only the first letter.
        #expect(WNAvatarMonogram.initial(for: "Ada Lovelace") == "A")
        #expect(WNAvatarMonogram.initial(for: "Marmota") == "M")
    }

    @Test func theMonogramIsUppercasedAndIgnoresSurroundingWhitespace() {
        #expect(WNAvatarMonogram.initial(for: "  ada  ") == "A")
        #expect(WNAvatarMonogram.initial(for: "\nmarmota") == "M")
    }

    @Test func aNamelessProfileFallsBackToAQuestionMark() {
        #expect(WNAvatarMonogram.initial(for: "") == "?")
        #expect(WNAvatarMonogram.initial(for: "   ") == "?")
    }

    @Test func nonLatinNamesKeepTheirFirstCharacter() {
        #expect(WNAvatarMonogram.initial(for: "Ярослав") == "Я")
        #expect(WNAvatarMonogram.initial(for: "小明") == "小")
    }
}
