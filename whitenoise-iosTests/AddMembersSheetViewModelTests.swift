import MarmotKit
import Testing
@testable import whitenoise_ios

@MainActor
struct AddMembersSheetViewModelTests {
    @Test func keyPackagePrewarmCoalescesRapidSelectionChanges() async {
        let model = AddMembersSheetViewModel()
        let alice = member(hexByte: "aa", npub: "npub1alice")
        let bob = member(hexByte: "bb", npub: "npub1bob")
        let (stream, continuation) = AsyncStream<[String]>.makeStream()
        var iterator = stream.makeAsyncIterator()

        model.selection.add(alice)
        model.scheduleMemberKeyPackagePrewarm(debounce: .seconds(60)) { refs in
            continuation.yield(refs)
        }
        model.selection.add(bob)
        model.scheduleMemberKeyPackagePrewarm(debounce: .zero) { refs in
            continuation.yield(refs)
        }

        let warmedRefs = await iterator.next()
        continuation.finish()
        model.cancelMemberKeyPackagePrewarm()

        #expect(warmedRefs == [alice.memberRef, bob.memberRef])
    }

    @Test func clearingSelectionCancelsPendingKeyPackagePrewarm() async {
        let model = AddMembersSheetViewModel()
        let alice = member(hexByte: "aa", npub: "npub1alice")
        var didPrewarm = false

        model.selection.add(alice)
        model.scheduleMemberKeyPackagePrewarm(debounce: .seconds(60)) { _ in
            didPrewarm = true
        }
        model.remove(accountIdHex: alice.accountIdHex)
        model.scheduleMemberKeyPackagePrewarm(debounce: .zero) { _ in
            didPrewarm = true
        }
        await Task.yield()

        #expect(!didPrewarm)
    }

    private func member(hexByte: String, npub: String) -> MemberRefFfi {
        MemberRefFfi(
            memberRef: npub,
            accountIdHex: String(repeating: hexByte, count: 32),
            npub: npub
        )
    }
}
