import Testing
@testable import whitenoise_ios

struct ContentSanitizerMultilineTests {

    @Test func clampsRunsOfBlankLines() {
        let flooded = "Line one" + String(repeating: "\n", count: 8) + "Line two"
        #expect(ContentSanitizer.multilineText(flooded) == "Line one\n\nLine two")
    }

    @Test func clampsCRLFAndLoneCRBlankLineRuns() {
        let crlf = "Line one" + String(repeating: "\r\n", count: 5) + "Line two"
        #expect(ContentSanitizer.multilineText(crlf) == "Line one\n\nLine two")
        let cr = "Line one" + String(repeating: "\r", count: 5) + "Line two"
        #expect(ContentSanitizer.multilineText(cr) == "Line one\n\nLine two")
    }

    @Test func keepsASingleBlankLineAndStripsBidi() {
        let raw = "Para one\n\nPara\u{202E}two"
        #expect(ContentSanitizer.multilineText(raw) == "Para one\n\nParatwo")
    }

    @Test func emptyOrWhitespaceOnlyReturnsNil() {
        #expect(ContentSanitizer.multilineText("\n\n\n\n") == nil)
        #expect(ContentSanitizer.multilineText("   ") == nil)
        #expect(ContentSanitizer.multilineText(nil) == nil)
    }
}
