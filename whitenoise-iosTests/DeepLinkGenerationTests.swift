import Testing
import Foundation
@testable import whitenoise_ios

/// Generated QR/share links must carry the canonical cross-client scheme in
/// every build flavor, while inbound parsing stays scheme-liberal.
struct DeepLinkGenerationTests {
    /// Checksum-valid npub from the NIP-19 test vectors.
    private let validNpub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
    private let groupIdHex = String(repeating: "ab", count: 32)

    @Test func generatedLinksUseCanonicalScheme() {
        #expect(DeepLink.profile(npub: validNpub).url.scheme == "marmot")
        #expect(DeepLink.chat(groupIdHex: groupIdHex).url.scheme == "marmot")
    }

    @Test func generatedLinksRoundTripThroughParse() {
        #expect(DeepLink.parse(DeepLink.profile(npub: validNpub).url) == .profile(npub: validNpub))
        #expect(DeepLink.parse(DeepLink.chat(groupIdHex: groupIdHex).url) == .chat(groupIdHex: groupIdHex))
    }

    @Test func flavorSchemeLinksStillParse() {
        for scheme in ["marmot", "marmot-staging", "whitenoise", "whitenoise-staging"] {
            #expect(DeepLink.parse(string: "\(scheme)://profile/\(validNpub)") == .profile(npub: validNpub), "scheme: \(scheme)")
        }
    }
}
