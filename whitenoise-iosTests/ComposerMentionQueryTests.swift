import Foundation
import MarmotKit
import Testing

@testable import whitenoise_ios

struct ComposerMentionQueryTests {
    private let jeffNpub = "npub1" + String(repeating: "q", count: 58)
    private let aliceNpub = "npub1" + String(repeating: "a", count: 58)

    @Test func activeMentionFindsTrailingAtSignQuery() {
        let draft = "hey @je"
        let session = ComposerMentionQuery.active(in: draft)
        #expect(session?.query == "je")
    }

    @Test func activeMentionRequiresWordBoundaryBeforeAt() {
        #expect(ComposerMentionQuery.active(in: "email@jeff") == nil)
    }

    @Test func activeMentionEndsAtWhitespace() {
        #expect(ComposerMentionQuery.active(in: "hey @jeff there") == nil)
    }

    @Test func activeMentionAllowsAtStart() {
        let session = ComposerMentionQuery.active(in: "@al")
        #expect(session?.query == "al")
    }

    @Test func filterMatchesDisplayNameAndNpub() {
        let candidates = [
            mentionCandidate(name: "Jeff", npub: jeffNpub, hex: "111"),
            mentionCandidate(name: "Alice", npub: aliceNpub, hex: "222"),
        ]
        #expect(
            ComposerMentionQuery.filter(candidates, matching: "je").map(\.displayName) == ["Jeff"])
        #expect(
            ComposerMentionQuery.filter(candidates, matching: "npub1a").map(\.displayName) == [
                "Alice"
            ])
        #expect(ComposerMentionQuery.filter(candidates, matching: "").count == 2)
    }

    @Test func filterMatchesMemberIdHexCaseInsensitively() {
        // Regression for #300: filter matches against precomputed lowercased
        // fields. Verify the memberIdHex match path and case-insensitivity
        // survive the precompute (an uppercase query must still match the
        // cached lowercased hex).
        let candidates = [
            mentionCandidate(name: "Jeff", npub: jeffNpub, hex: "deadbeef01"),
            mentionCandidate(name: "Alice", npub: aliceNpub, hex: "cafef00d02"),
        ]
        #expect(
            ComposerMentionQuery.filter(candidates, matching: "DEADBEEF").map(\.displayName) == [
                "Jeff"
            ])
        #expect(
            ComposerMentionQuery.filter(candidates, matching: "cafe").map(\.displayName) == [
                "Alice"
            ])
        #expect(ComposerMentionQuery.filter(candidates, matching: "JE").map(\.displayName) == ["Jeff"])
    }

    @Test func replacingInsertsDisplayNameMention() throws {
        let draft = "ping @je"
        let session = try #require(ComposerMentionQuery.active(in: draft))
        let updated = ComposerMentionQuery.replacing(session: session, in: draft, with: "Jeff")
        #expect(updated == "ping @Jeff ")
    }

    @Test func canonicalizeDisplayNameMentionForSend() {
        let candidates = [
            mentionCandidate(name: "Jeff", npub: jeffNpub, hex: "111")
        ]
        let outgoing = ComposerMentionCanonicalizer.canonicalize(
            "ping @Jeff ",
            candidates: candidates
        )
        #expect(outgoing == "ping @\(jeffNpub) ")
    }

    @Test func canonicalizeRefusesAmbiguousNamesWithoutASelection() {
        // Two members share the display name: without an explicit tap, the
        // mention stays literal text — a peer cloning a name cannot capture
        // an unselected mention through match ordering.
        let candidates = [
            mentionCandidate(name: "Jeff", npub: jeffNpub, hex: "111"),
            mentionCandidate(name: "Jeff", npub: aliceNpub, hex: "222"),
        ]
        let outgoing = ComposerMentionCanonicalizer.canonicalize(
            "ping @Jeff ",
            candidates: candidates
        )
        #expect(outgoing == "ping @Jeff ")
    }

    @Test func canonicalizeResolvesAmbiguousNamesThroughTheTappedIdentity() {
        let candidates = [
            mentionCandidate(name: "Jeff", npub: jeffNpub, hex: "111"),
            mentionCandidate(name: "Jeff", npub: aliceNpub, hex: "222"),
        ]
        let outgoing = ComposerMentionCanonicalizer.canonicalize(
            "ping @Jeff ",
            candidates: candidates,
            selectedNpubByDisplayName: ["Jeff": aliceNpub]
        )
        #expect(outgoing == "ping @\(aliceNpub) ")
    }

    @Test func canonicalizeIgnoresSelectionsPointingOutsideTheRoster() {
        // A stale selection whose npub no longer belongs to any member with
        // that name must not resolve the mention.
        let candidates = [
            mentionCandidate(name: "Jeff", npub: jeffNpub, hex: "111"),
            mentionCandidate(name: "Jeff", npub: aliceNpub, hex: "222"),
        ]
        let outgoing = ComposerMentionCanonicalizer.canonicalize(
            "ping @Jeff ",
            candidates: candidates,
            selectedNpubByDisplayName: ["Jeff": "npub1notinroster"]
        )
        #expect(outgoing == "ping @Jeff ")
    }

    @Test func canonicalizeDisplayNameMentionWithSpacesAndPunctuation() {
        let candidates = [
            mentionCandidate(name: "Jeff Smith", npub: jeffNpub, hex: "111")
        ]
        let outgoing = ComposerMentionCanonicalizer.canonicalize(
            "ping (@Jeff Smith), are you around?",
            candidates: candidates
        )
        #expect(outgoing == "ping (@\(jeffNpub)), are you around?")
    }

    @Test func canonicalizePrefersLongestDisplayName() {
        let candidates = [
            mentionCandidate(name: "Jeff", npub: jeffNpub, hex: "111"),
            mentionCandidate(name: "Jeff Smith", npub: aliceNpub, hex: "222"),
        ]
        let outgoing = ComposerMentionCanonicalizer.canonicalize(
            "ping @Jeff Smith ",
            candidates: candidates
        )
        #expect(outgoing == "ping @\(aliceNpub) ")
    }

    @Test func canonicalizeKeepsNonMentionAtSignsAndLongerWords() {
        let candidates = [
            mentionCandidate(name: "Jeff", npub: jeffNpub, hex: "111")
        ]
        let outgoing = ComposerMentionCanonicalizer.canonicalize(
            "mail me@Jeff or ping @Jefferson or open /@Jeff",
            candidates: candidates
        )
        #expect(outgoing == "mail me@Jeff or ping @Jefferson or open /@Jeff")
    }

    @Test func hidesAutocompleteForCompleteNpubBody() {
        let partial = "npub1" + String(repeating: "q", count: 57)
        #expect(!ComposerMentionQuery.looksLikeCompleteNpub(partial))
        #expect(ComposerMentionQuery.looksLikeCompleteNpub(jeffNpub))
    }

    @Test func groupMemberDetailsProfileLookupsUseNostrMemberId() {
        let member = GroupMemberDetailsFfi(
            memberIdHex: "nostr-account-id",
            account: "local-account-label",
            local: false,
            isAdmin: false,
            isSelf: false,
            npub: aliceNpub,
            displayName: nil
        )

        #expect(
            GroupMemberDetailsPresentation.profileAccountIdHex(for: member) == "nostr-account-id")
    }

    @Test func groupMemberDetailsProfileLookupsUseNostrMemberIdWithoutAccountLabel() {
        let missingAccount = GroupMemberDetailsFfi(
            memberIdHex: "mls-member-id",
            account: nil,
            local: false,
            isAdmin: false,
            isSelf: false,
            npub: aliceNpub,
            displayName: nil
        )
        let emptyAccount = GroupMemberDetailsFfi(
            memberIdHex: "mls-member-id",
            account: "",
            local: false,
            isAdmin: false,
            isSelf: false,
            npub: aliceNpub,
            displayName: nil
        )

        #expect(
            GroupMemberDetailsPresentation.profileAccountIdHex(for: missingAccount)
                == "mls-member-id")
        #expect(
            GroupMemberDetailsPresentation.profileAccountIdHex(for: emptyAccount) == "mls-member-id"
        )
    }

    @Test func fallbackMemberCandidateEncodesNpubWithoutMarmotClient() throws {
        let npub = "npub10elfcs4fr0l0r8af98jlmgdh9c8tcxjvz9qkw038js35mp4dma8qzvjptg"
        let accountIdHex = try #require(NostrProfileReference.pubkeyHex(fromBech32: npub))
        let member = AppGroupMemberRecordFfi(
            memberIdHex: "mls-member-id",
            account: accountIdHex,
            local: false
        )

        let candidate = try #require(ComposerMentionCandidate(member: member, appState: AppState()))

        #expect(candidate.npub == npub)
        #expect(candidate.displayName == IdentityFormatter.short(accountIdHex))
    }

    @Test func fallbackMemberCandidateRejectsInvalidAccountHex() {
        let member = AppGroupMemberRecordFfi(
            memberIdHex: "mls-member-id",
            account: "account-label",
            local: false
        )

        #expect(ComposerMentionCandidate(member: member, appState: AppState()) == nil)
    }

    @Test func mentionCandidateCacheKeyTreatsSameGenerationsAsEqual() {
        // Regression for #300: ConversationViewModel caches the `@`-mention
        // candidate list and reuses it across keystrokes, rebuilding only when
        // the roster or profile generation changes. Equal generation pairs must
        // compare equal so the cache is reused (no per-keystroke rebuild).
        let a = MentionCandidateCacheKey(
            rosterGeneration: 7, profileGeneration: 3)
        let b = MentionCandidateCacheKey(
            rosterGeneration: 7, profileGeneration: 3)
        #expect(a == b)
    }

    @Test func mentionCandidateCacheKeyInvalidatesWhenEitherGenerationChanges() {
        // A bump in either the roster generation (membership/admin change) or
        // the profile generation (resolved display name/avatar/npub) must make
        // the key compare unequal so a freshly resolved candidate list is built.
        let base = MentionCandidateCacheKey(
            rosterGeneration: 7, profileGeneration: 3)
        let rosterBumped = MentionCandidateCacheKey(
            rosterGeneration: 8, profileGeneration: 3)
        let profileBumped = MentionCandidateCacheKey(
            rosterGeneration: 7, profileGeneration: 4)
        #expect(base != rosterBumped)
        #expect(base != profileBumped)
    }
}

private func mentionCandidate(name: String, npub: String, hex: String) -> ComposerMentionCandidate {
    ComposerMentionCandidate(
        details: GroupMemberDetailsFfi(
            memberIdHex: hex,
            account: hex,
            local: false,
            isAdmin: false,
            isSelf: false,
            npub: npub,
            displayName: name
        ),
        appState: AppState()
    )
}
