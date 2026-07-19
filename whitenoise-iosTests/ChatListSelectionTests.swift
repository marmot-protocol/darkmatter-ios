import Foundation
import Testing
@testable import whitenoise_ios

struct ChatListSelectionTests {
    @Test func archiveTogglesToUnarchiveOnlyWhenAllArchived() {
        #expect(ChatListSelection.bulkArchiveAction(archivedFlags: [true, true]) == .unarchive)
        #expect(ChatListSelection.bulkArchiveAction(archivedFlags: [true, false]) == .archive)
        #expect(ChatListSelection.bulkArchiveAction(archivedFlags: [false, false]) == .archive)
        // Empty selection never resolves to unarchive.
        #expect(ChatListSelection.bulkArchiveAction(archivedFlags: []) == .archive)
    }

    @Test func muteTogglesToUnmuteOnlyWhenAllMuted() {
        #expect(ChatListSelection.bulkMuteMutes(mutedFlags: [true, true]) == false)
        #expect(ChatListSelection.bulkMuteMutes(mutedFlags: [true, false]) == true)
        #expect(ChatListSelection.bulkMuteMutes(mutedFlags: []) == true)
    }

    @Test func toggleAndReconcile() {
        var selected: Set<String> = []
        selected = ChatListSelection.toggling(selected, id: "a")
        selected = ChatListSelection.toggling(selected, id: "b")
        #expect(selected == ["a", "b"])
        selected = ChatListSelection.toggling(selected, id: "a")
        #expect(selected == ["b"])
        // A selection whose chat scrolled out of the visible set is dropped.
        #expect(ChatListSelection.reconcile(["a", "b"], visibleIds: ["b", "c"]) == ["b"])
        #expect(ChatListSelection.selectAll(["a", "b", "c"]) == ["a", "b", "c"])
    }
}

struct MessageBulkCopyTests {
    @Test func combinedCopyJoinsNonEmptyBodiesInOrder() {
        let text = MessageSelectionPolicy.combinedCopyText(["first", "  ", "second", ""])
        #expect(text == "first\n\nsecond")
        #expect(MessageSelectionPolicy.canCopy(selectedCount: 2, anyHasText: true))
        #expect(!MessageSelectionPolicy.canCopy(selectedCount: 0, anyHasText: true))
        #expect(!MessageSelectionPolicy.canCopy(selectedCount: 2, anyHasText: false))
    }
}
