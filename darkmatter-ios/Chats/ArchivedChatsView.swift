import SwiftUI
import MarmotKit

/// Archived conversations, reached from the chats list. Same rows as the main
/// list; swipe to restore. Tapping a row opens the conversation via the parent
/// stack's navigation destination.
struct ArchivedChatsView: View {
    @Environment(AppState.self) private var appState
    @Bindable var viewModel: ChatsListViewModel

    var body: some View {
        Group {
            if viewModel.archivedItems.isEmpty {
                ContentUnavailableView(
                    "No archived chats",
                    systemImage: "archivebox",
                    description: Text("Archived conversations show up here.")
                )
            } else {
                List {
                    ForEach(viewModel.archivedItems) { item in
                        ZStack {
                            ChatRow(item: item)
                            NavigationLink(value: item.group.groupIdHex) { EmptyView() }
                                .opacity(0)
                        }
                        .swipeActions(edge: .trailing) {
                            Button {
                                Task { await setArchived(group: item.group, archived: false) }
                            } label: {
                                Label("Unarchive", systemImage: "tray.and.arrow.up")
                            }
                            .tint(.blue)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("Archived")
        .navigationBarTitleDisplayMode(.inline)
    }

    @MainActor
    private func setArchived(group: AppGroupRecordFfi, archived: Bool) async {
        guard let ref = appState.activeAccountRef else { return }
        do {
            _ = try appState.marmot.setGroupArchived(
                accountRef: ref,
                groupIdHex: group.groupIdHex,
                archived: archived
            )
            Haptics.success()
        } catch {
            Haptics.error()
            appState.present(.error("Couldn't unarchive chat", message: error.localizedDescription))
        }
    }
}
