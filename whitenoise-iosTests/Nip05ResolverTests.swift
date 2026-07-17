import Foundation
import Testing
@testable import whitenoise_ios

struct Nip05ResolverTests {
    private let hex = String(repeating: "ab", count: 32)

    @Test func buildsSafeLookupURLs() throws {
        let url = try #require(Nip05Resolver.lookupURL(name: "Alice", domain: "Example.com"))

        #expect(url.scheme == "https")
        #expect(url.host == "example.com")
        #expect(url.path == "/.well-known/nostr.json")
        #expect(url.query == "name=alice")
        #expect(url.user == nil)
        #expect(url.port == nil)
    }

    @Test func rejectsUnsafeLookupHosts() {
        #expect(Nip05Resolver.lookupURL(name: "a", domain: "127.0.0.1") == nil)
        #expect(Nip05Resolver.lookupURL(name: "a", domain: "10.0.0.8") == nil)
        #expect(Nip05Resolver.lookupURL(name: "a", domain: "8.8.8.8") == nil)
        #expect(Nip05Resolver.lookupURL(name: "a", domain: "localhost") == nil)
        #expect(Nip05Resolver.lookupURL(name: "a", domain: "[::1]") == nil)
        #expect(Nip05Resolver.lookupURL(name: "a", domain: "example.com:8443") == nil)
        #expect(Nip05Resolver.lookupURL(name: "a", domain: "user@example.com") == nil)
        #expect(Nip05Resolver.lookupURL(name: "a", domain: "exa mple.com") == nil)
    }

    @Test func resolvesNameToNormalizedPubkey() async {
        let document = "{\"names\":{\"alice\":\"\(hex.uppercased())\"}}"

        let result = await Nip05Resolver.resolve(
            name: "alice",
            domain: "example.com",
            transport: stub(returning: document)
        )

        #expect(result == .resolved(accountIdHex: hex))
    }

    @Test func matchesNamesCaseInsensitively() async {
        let document = "{\"names\":{\"Alice\":\"\(hex)\"}}"

        let result = await Nip05Resolver.resolve(
            name: "alice",
            domain: "example.com",
            transport: stub(returning: document)
        )

        #expect(result == .resolved(accountIdHex: hex))
    }

    @Test func missingNameOrInvalidPubkeyIsNoProfile() async {
        let missing = await Nip05Resolver.resolve(
            name: "alice",
            domain: "example.com",
            transport: stub(returning: "{\"names\":{\"bob\":\"\(hex)\"}}")
        )
        let badKey = await Nip05Resolver.resolve(
            name: "alice",
            domain: "example.com",
            transport: stub(returning: "{\"names\":{\"alice\":\"nope\"}}")
        )

        #expect(missing == .noProfile)
        #expect(badKey == .noProfile)
    }

    @MainActor
    @Test func resolvedAccountChangeShedsTheVerifiedBadge() async {
        let model = ProfileViewModel()
        model.applyResolvedAccount(hex)
        await model.verifyDeclaredNip05(
            "alice@example.com",
            transport: stub(returning: "{\"names\":{\"alice\":\"\(hex)\"}}")
        )
        #expect(model.verifiedNip05 == "alice@example.com")

        // Same account re-resolves: the badge survives.
        model.applyResolvedAccount(hex)
        #expect(model.verifiedNip05 == "alice@example.com")

        // A different pubkey takes over the surface: the badge — earned by
        // the previous pubkey — must not carry across, and the attempt
        // memo resets so the new account gets its own verification.
        model.applyResolvedAccount(String(repeating: "f", count: 64))
        #expect(model.verifiedNip05 == nil)
    }

    @Test func malformedDocumentsAndTransportFailuresFail() async {
        let malformed = await Nip05Resolver.resolve(
            name: "alice",
            domain: "example.com",
            transport: stub(returning: "not json")
        )
        let wrongShape = await Nip05Resolver.resolve(
            name: "alice",
            domain: "example.com",
            transport: stub(returning: "{\"names\":[1,2]}")
        )
        let failing = await Nip05Resolver.resolve(
            name: "alice",
            domain: "example.com",
            transport: { _, _ in throw URLError(.timedOut) }
        )

        #expect(malformed == .failed)
        #expect(wrongShape == .noProfile)
        #expect(failing == .failed)
    }

    @Test func unsafeAddressesNeverReachTheTransport() async {
        let result = await Nip05Resolver.resolve(
            name: "alice",
            domain: "127.0.0.1",
            transport: { _, _ in
                Issue.record("transport must not be called for unsafe hosts")
                throw URLError(.badURL)
            }
        )

        #expect(result == .invalidAddress)
    }

    @Test func verifiedOnlyWhenDeclaredAddressResolvesBackToTheSamePubkey() async {
        let matching = "{\"names\":{\"alice\":\"\(hex)\"}}"
        let other = "{\"names\":{\"alice\":\"\(String(repeating: "cd", count: 32))\"}}"

        let verified = await Nip05Resolver.verifies(
            declaredAddress: "alice@example.com",
            accountIdHex: hex.uppercased(),
            transport: stub(returning: matching)
        )
        let mismatched = await Nip05Resolver.verifies(
            declaredAddress: "alice@example.com",
            accountIdHex: hex,
            transport: stub(returning: other)
        )
        let invalidDeclaration = await Nip05Resolver.verifies(
            declaredAddress: "not-an-address",
            accountIdHex: hex,
            transport: stub(returning: matching)
        )

        #expect(verified)
        #expect(!mismatched)
        #expect(!invalidDeclaration)
    }

    private func stub(returning body: String) -> Nip05Resolver.Transport {
        { request, _ in
            let response = HTTPURLResponse(
                url: request.url ?? URL(fileURLWithPath: "/"),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
            return (Data(body.utf8), response ?? URLResponse())
        }
    }
}
