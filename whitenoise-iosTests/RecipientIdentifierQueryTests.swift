import Testing
@testable import whitenoise_ios

struct RecipientIdentifierQueryTests {
    private let hex = String(repeating: "ab", count: 32)
    private var npub: String { NostrProfileReference.npub(fromAccountIdHex: hex) ?? "" }

    @Test func classifiesProfileReferenceForms() {
        #expect(RecipientIdentifierQuery.classify(npub) == .profileReference(npub))
        #expect(RecipientIdentifierQuery.classify(" \(npub)\n") == .profileReference(npub))
        #expect(RecipientIdentifierQuery.classify("nostr:\(npub)") == .profileReference(npub))
        #expect(RecipientIdentifierQuery.classify(hex.uppercased()) == .profileReference(hex))
        #expect(
            RecipientIdentifierQuery.classify("\(DeepLink.scheme)://profile/\(npub)")
                == .profileReference(npub)
        )
    }

    @Test func classifiesNip05Addresses() {
        #expect(
            RecipientIdentifierQuery.classify("Alice@Example.COM")
                == .nip05(name: "alice", domain: "example.com")
        )
        #expect(
            RecipientIdentifierQuery.classify("  _@relay.example.org ")
                == .nip05(name: "_", domain: "relay.example.org")
        )
    }

    @Test func treatsPlainTextAndInvalidShapesAsNoIdentifier() {
        #expect(RecipientIdentifierQuery.classify("alice smith") == .none)
        #expect(RecipientIdentifierQuery.classify("") == .none)
        #expect(RecipientIdentifierQuery.classify("@example.com") == .none)
        #expect(RecipientIdentifierQuery.classify("alice@") == .none)
        #expect(RecipientIdentifierQuery.classify("alice@no-dot") == .none)
        // A corrupted npub checksum must not fall through to the NIP-05 path.
        #expect(RecipientIdentifierQuery.classify(String(npub.dropLast()) + "x") == .none)
    }

    @Test func prefersProfileReferenceOverNip05WhenBothCouldMatch() {
        // A bare hex key contains no "@" so it can't be an address, but make
        // the precedence explicit: reference classification runs first.
        if case .profileReference = RecipientIdentifierQuery.classify(hex) {
        } else {
            Issue.record("expected a profile reference")
        }
    }
}
