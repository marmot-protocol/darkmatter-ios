import Testing
@testable import whitenoise_ios

struct RecipientSearchTests {
    private let alice = String(repeating: "aa", count: 32)
    private let bob = String(repeating: "bb", count: 32)
    private let carol = String(repeating: "cc", count: 32)

    @Test func blankQueryReturnsAllCandidatesInInputOrder() {
        let candidates = [candidate(alice), candidate(bob)]

        let result = RecipientSearch.browse(candidates, query: "   ") { _ in .init() }

        #expect(result.map(\.accountIdHex) == [alice, bob])
    }

    @Test func matchesNamesCaseAndDiacriticInsensitively() {
        let candidates = [candidate(alice), candidate(bob)]

        let result = RecipientSearch.browse(candidates, query: "  JOSÉ ") { candidate in
            candidate.accountIdHex == self.alice ? .init(displayName: "jose garcía") : .init()
        }

        #expect(result.map(\.accountIdHex) == [alice])
    }

    @Test func ranksNamePrefixMatchesBeforeContainedMatches() {
        let candidates = [candidate(alice), candidate(bob), candidate(carol)]

        let result = RecipientSearch.browse(candidates, query: "an") { candidate in
            switch candidate.accountIdHex {
            case self.alice: .init(displayName: "Joanne")
            case self.bob: .init(displayName: "Anders")
            default: .init(displayName: "Zoe")
            }
        }

        #expect(result.map(\.accountIdHex) == [bob, alice])
    }

    @Test func matchesPrivateNicknameAndNip05() {
        let candidates = [candidate(alice), candidate(bob)]

        let byNickname = RecipientSearch.browse(candidates, query: "boss") { candidate in
            candidate.accountIdHex == self.alice ? .init(nickname: "The Boss") : .init()
        }
        let byAddress = RecipientSearch.browse(candidates, query: "example.com") { candidate in
            candidate.accountIdHex == self.bob ? .init(nip05: "bob@example.com") : .init()
        }

        #expect(byNickname.map(\.accountIdHex) == [alice])
        #expect(byAddress.map(\.accountIdHex) == [bob])
    }

    @Test func matchesNpubAndHexPrefixesButNotShortFragments() {
        let candidates = [candidate(alice)]
        let npubPrefix = String(candidates[0].npub.prefix(8))

        let byNpub = RecipientSearch.browse(candidates, query: npubPrefix) { _ in .init() }
        let byHex = RecipientSearch.browse(candidates, query: String(alice.prefix(6))) { _ in .init() }
        let tooShort = RecipientSearch.browse(candidates, query: "aa") { _ in .init() }

        #expect(byNpub.map(\.accountIdHex) == [alice])
        #expect(byHex.map(\.accountIdHex) == [alice])
        #expect(tooShort.isEmpty)
    }

    @Test func excludesListedAccountsAndDeduplicatesKeepingFirst() {
        let duplicate = candidate(alice.uppercased())
        let candidates = [candidate(alice), duplicate, candidate(bob)]

        let result = RecipientSearch.browse(
            candidates,
            query: "",
            excludedAccountIds: [bob.uppercased()]
        ) { _ in .init() }

        #expect(result.count == 1)
        #expect(result.first?.accountIdHex == alice)
    }

    private func candidate(_ hex: String) -> RecipientCandidate {
        RecipientCandidate(
            accountIdHex: hex,
            npub: NostrProfileReference.npub(fromAccountIdHex: hex.lowercased()) ?? hex,
            lastActivityAt: 0,
            directChatGroupIdHex: nil,
            sharedChatCount: 1
        )
    }
}
