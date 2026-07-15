import Testing
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
struct RecipientSelectionTests {
    private let alice = String(repeating: "aa", count: 32)
    private let bob = String(repeating: "bb", count: 32)

    @Test func togglePreservesSelectionOrderAndSupportsRemoval() {
        let selection = RecipientSelection()

        selection.toggle(member(alice))
        selection.toggle(member(bob))
        #expect(selection.members.map(\.accountIdHex) == [alice, bob])
        #expect(selection.count == 2)

        selection.toggle(member(alice))
        #expect(selection.members.map(\.accountIdHex) == [bob])
        #expect(selection.isSelected(accountIdHex: bob))
        #expect(!selection.isSelected(accountIdHex: alice))
    }

    @Test func deduplicatesByNormalizedAccountId() {
        let selection = RecipientSelection()

        #expect(selection.add(member(alice)))
        #expect(selection.add(member(alice.uppercased())))
        #expect(selection.count == 1)
        #expect(selection.isSelected(accountIdHex: " \(alice.uppercased()) "))
    }

    @Test func refusesExcludedPeople() {
        let selection = RecipientSelection()

        let added = selection.add(member(alice), excludedAccountIds: [alice])

        #expect(!added)
        #expect(selection.isEmpty)
    }

    @Test func removalMatchesByNormalizedAccountId() {
        let selection = RecipientSelection()
        selection.add(member(alice))

        selection.remove(accountIdHex: alice.uppercased())

        #expect(selection.isEmpty)
    }

    @Test func memberRefsSubmitTheStagedReferenceForms() {
        let selection = RecipientSelection()
        selection.add(MemberRefFfi(memberRef: "nprofile1abc", accountIdHex: alice, npub: "npub1a"))

        #expect(selection.memberRefs == ["nprofile1abc"])
    }

    @Test func candidateMembersSubmitTheirNpub() {
        let candidate = RecipientCandidate(
            accountIdHex: alice,
            npub: "npub1candidate",
            lastActivityAt: 0,
            directChatGroupIdHex: nil,
            sharedChatCount: 1
        )

        let member = RecipientSelection.member(for: candidate)

        #expect(member.memberRef == "npub1candidate")
        #expect(member.accountIdHex == alice)
    }

    private func member(_ hex: String) -> MemberRefFfi {
        MemberRefFfi(memberRef: "npub1\(hex.prefix(8))", accountIdHex: hex, npub: "npub1\(hex.prefix(8))")
    }
}
