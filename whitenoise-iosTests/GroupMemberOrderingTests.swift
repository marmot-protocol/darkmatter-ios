import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct GroupMemberOrderingTests {
    @Test func ordersSelfThenAdminsThenNamesWithStableTiebreak() {
        let you = member("11", isSelf: true)
        let admin = member("22", isAdmin: true)
        let zoe = member("33")
        let anna = member("44")
        let names = ["11": "Zed", "22": "Boss", "33": "zoe", "44": "Anna"]

        let ordered = GroupMemberOrdering.ordered([zoe, anna, admin, you], namesByMemberId: names)

        #expect(ordered.map(\.memberIdHex) == [you, admin, anna, zoe].map(\.memberIdHex))
    }

    @Test func equalNamesFallBackToMemberIdOrder() {
        let one = member("22")
        let two = member("11")
        let names = ["11": "Same", "22": "Same"]

        let ordered = GroupMemberOrdering.ordered([one, two], namesByMemberId: names)

        #expect(ordered.map(\.memberIdHex) == [two, one].map(\.memberIdHex))
    }

    @Test func filtersByNameCaseInsensitivelyAndByNpubPrefix() {
        let anna = member("11", npub: "npub1anna")
        let zoe = member("22", npub: "npub1zoe")
        let names = ["11": "Anna Ström", "22": "Zoe"]

        let byName = GroupMemberOrdering.filtered([anna, zoe], query: "  ström", namesByMemberId: names)
        let byNpub = GroupMemberOrdering.filtered([anna, zoe], query: "npub1z", namesByMemberId: names)
        let all = GroupMemberOrdering.filtered([anna, zoe], query: "  ", namesByMemberId: names)

        #expect(byName.map(\.memberIdHex) == ["11"])
        #expect(byNpub.map(\.memberIdHex) == ["22"])
        #expect(all.count == 2)
    }

    @Test func previewCollapsesOnlyWhenNotSearchingOrExpanded() {
        let members = (0..<9).map { member("\($0)") }

        let collapsed = GroupMemberOrdering.visible(members, isSearching: false, isExpanded: false)
        let searching = GroupMemberOrdering.visible(members, isSearching: true, isExpanded: false)
        let expanded = GroupMemberOrdering.visible(members, isSearching: false, isExpanded: true)
        let small = GroupMemberOrdering.visible(
            Array(members.prefix(3)),
            isSearching: false,
            isExpanded: false
        )

        #expect(collapsed.count == GroupMemberOrdering.previewCount)
        #expect(searching.count == 9)
        #expect(expanded.count == 9)
        #expect(small.count == 3)
    }

    private func member(
        _ id: String,
        isSelf: Bool = false,
        isAdmin: Bool = false,
        npub: String = "npub1x"
    ) -> GroupMemberDetailsFfi {
        GroupMemberDetailsFfi(
            memberIdHex: id,
            account: nil,
            local: isSelf,
            isAdmin: isAdmin,
            isSelf: isSelf,
            npub: npub,
            displayName: nil
        )
    }
}
