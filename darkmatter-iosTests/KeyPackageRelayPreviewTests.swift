import Testing
import Foundation
@testable import darkmatter_ios

/// #53 — the key-package relay preview must strip bidi / zero-width characters,
/// not just C0/DEL, so relay URLs can't be visually spoofed.
@MainActor
struct KeyPackageRelayPreviewTests {

    @Test func stripsBidiAndZeroWidthFromRelayPreview() {
        let preview = KeyPackagesView.sanitizedRelays([
            "wss://relay\u{202E}evil.example",
            "wss://a\u{200B}b.example"
        ])
        #expect(!preview.unicodeScalars.contains { $0.value == 0x202E })
        #expect(!preview.unicodeScalars.contains { $0.value == 0x200B })
        #expect(preview.contains("wss://relayevil.example"))
        #expect(preview.contains("wss://ab.example"))
    }

    @Test func limitsToFourRelays() {
        let many = (0..<10).map { "wss://r\($0).example" }
        #expect(KeyPackagesView.sanitizedRelays(many).components(separatedBy: ", ").count == 4)
    }
}
