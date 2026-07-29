import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

struct RecipientSearchTests {
    private let alice = String(repeating: "aa", count: 32)
    private let bob = String(repeating: "bb", count: 32)
    private let carol = String(repeating: "cc", count: 32)

    @Test func completingOlderDirectoryLoadCannotClearNewerTaskSlot() {
        let older = UUID()
        let newer = UUID()

        #expect(!RecipientDirectory.shouldClearLoadTask(
            currentTaskID: newer,
            completingTaskID: older
        ))
        #expect(RecipientDirectory.shouldClearLoadTask(
            currentTaskID: newer,
            completingTaskID: newer
        ))
    }

    @Test func directoryResetsAndRejectsCommitsAcrossAccountSwitches() {
        let task = UUID()

        #expect(RecipientDirectory.shouldResetForAccountChange(
            loadedAccountRef: "account-a",
            loadingAccountRef: nil,
            requestedAccountRef: "account-b"
        ))
        #expect(!RecipientDirectory.shouldResetForAccountChange(
            loadedAccountRef: "account-a",
            loadingAccountRef: "account-a",
            requestedAccountRef: "account-a"
        ))
        #expect(!RecipientDirectory.loadRequestIsCurrent(
            currentTaskID: task,
            currentAccountRef: "account-a",
            activeAccountRef: "account-b",
            completingTaskID: task,
            completingAccountRef: "account-a"
        ))
        #expect(RecipientDirectory.loadRequestIsCurrent(
            currentTaskID: task,
            currentAccountRef: "account-b",
            activeAccountRef: "account-b",
            completingTaskID: task,
            completingAccountRef: "account-b"
        ))
    }

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
        // The stored field's diacritics must fold too, not just the query's.
        let foldedField = RecipientSearch.browse(candidates, query: "garcia") { candidate in
            candidate.accountIdHex == self.alice ? .init(displayName: "José García") : .init()
        }

        #expect(result.map(\.accountIdHex) == [alice])
        #expect(foldedField.map(\.accountIdHex) == [alice])
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

    @Test func liveSearchRunsForAnyNonemptyFreeTextAndLeavesIdentifiersToResolver() {
        #expect(!RecipientUserSearch.shouldSearch(query: " ", isIdentifierQuery: false))
        #expect(RecipientUserSearch.shouldSearch(query: "a", isIdentifierQuery: false))
        #expect(RecipientUserSearch.shouldSearch(query: "  al  ", isIdentifierQuery: false))
        #expect(!RecipientUserSearch.shouldSearch(query: "alice", isIdentifierQuery: true))
    }

    @Test func streamedResultsRerankAcrossBatchesAndDeduplicateBestMatch() {
        let results = RecipientUserSearch.sortedUniqueResults([
            searchResult(bob, radius: 2, field: .displayName, quality: .prefix),
            searchResult(alice, radius: 1, field: .about, quality: .contains),
            searchResult(carol, radius: 1, field: .name, quality: .exact),
            searchResult(bob, radius: 1, field: .displayName, quality: .prefix),
        ], followedAccountIds: [bob])

        #expect(results.map(\.accountIdHex) == [bob, carol, alice])
        #expect(results.first?.radius == 1)
    }

    @Test func discoveryResultsUseProviderRankBeforeLocalMatchStrength() {
        let results = RecipientUserSearch.sortedUniqueResults([
            searchResult(
                alice,
                radius: .max,
                field: .name,
                quality: .exact,
                providerRank: 0.2
            ),
            searchResult(
                bob,
                radius: .max,
                field: .about,
                quality: .contains,
                providerRank: 0.9
            ),
        ])

        #expect(results.map(\.accountIdHex) == [bob, alice])
    }

    @Test func followedRecipientsSortFirstAndKnownChatContextSurvivesMerge() {
        let knownAlice = candidate(alice)
        let discoveredAlice = RecipientCandidate(
            accountIdHex: alice,
            npub: knownAlice.npub,
            lastActivityAt: 0,
            directChatGroupIdHex: nil,
            sharedChatCount: 0,
            searchRadius: 1,
            isFollowedBySearcher: true
        )
        let discoveredBob = RecipientCandidate(
            accountIdHex: bob,
            npub: candidate(bob).npub,
            lastActivityAt: 0,
            directChatGroupIdHex: nil,
            sharedChatCount: 0,
            searchRadius: 2
        )

        let merged = RecipientSearch.merge(
            known: [knownAlice],
            discovered: [discoveredAlice, discoveredBob],
            excludedAccountIds: []
        )

        #expect(merged.map(\.accountIdHex) == [alice, bob])
        #expect(merged.first?.isFollowedBySearcher == true)
        #expect(merged.first?.sharedChatCount == knownAlice.sharedChatCount)
        #expect(merged.first?.searchRadius == 1)
    }

    @Test func remoteFollowSortsAheadOfKnownNonFollow() {
        let followedBob = RecipientCandidate(
            accountIdHex: bob,
            npub: candidate(bob).npub,
            lastActivityAt: 0,
            directChatGroupIdHex: nil,
            sharedChatCount: 0,
            searchRadius: 1,
            isFollowedBySearcher: true
        )

        let merged = RecipientSearch.merge(
            known: [candidate(alice)],
            discovered: [followedBob]
        )

        #expect(merged.map(\.accountIdHex) == [bob, alice])
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

    private func searchResult(
        _ hex: String,
        radius: UInt8,
        field: MatchedFieldFfi,
        quality: MatchQualityFfi,
        providerRank: Double? = nil
    ) -> UserDirectorySearchResultFfi {
        UserDirectorySearchResultFfi(
            accountIdHex: hex,
            npub: candidate(hex).npub,
            radius: radius,
            matchedField: field,
            matchQuality: quality,
            providerRank: providerRank,
            profile: nil
        )
    }
}

@MainActor
struct ProfileFollowTests {
    private let peer = String(repeating: "dd", count: 32)

    @Test func profileLoadsFollowStatusFromTheBindingAdapter() async {
        let model = ProfileViewModel()
        model.applyResolvedAccount(peer)

        await model.prepareFollowStatus(initialValue: false) {
            true
        }

        #expect(model.isFollowing == true)
        #expect(!model.isLoadingFollow)
    }

    @Test func profileTogglePublishesTheOppositeStateAndUsesReturnedResult() async throws {
        let model = ProfileViewModel()
        let appState = AppState(client: try MarmotClient.testClient())
        model.applyResolvedAccount(peer)
        await model.prepareFollowStatus(initialValue: true, load: nil)
        var requestedState: Bool?

        await model.toggleFollow(using: appState) { desired in
            requestedState = desired
            return desired
        }

        #expect(requestedState == false)
        #expect(model.isFollowing == false)
        #expect(!model.isUpdatingFollow)
    }
}
