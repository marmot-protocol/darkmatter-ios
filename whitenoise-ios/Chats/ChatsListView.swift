import SwiftUI
import MarmotKit

struct ChatsListView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel: ChatsListViewModel?
    @State private var showNewChat = false
    @State private var showSettings = false
    @State private var path: [ChatNavigationTarget] = []
    @State private var searchText = ""
    @State private var scope: ChatScope = .active
    @State private var selectedChatIds = Set<String>()
    @State private var showBulkDeleteConfirmation = false
    @FocusState private var searchFocused: Bool

    enum ChatScope: CaseIterable, Hashable {
        case active, archived, unread

        var title: LocalizedStringKey {
            switch self {
            case .active: "Active"
            case .archived: "Archived"
            case .unread: "Unread"
            }
        }

        var systemImage: String {
            switch self {
            case .active: "bubble.left.and.bubble.right"
            case .archived: "archivebox"
            case .unread: "circle.fill"
            }
        }
    }

    struct ChatNavigationTarget: Hashable {
        let groupIdHex: String
        let messageIdHex: String?
        let unreadMessageIdHex: String?

        init(
            groupIdHex: String,
            messageIdHex: String? = nil,
            unreadMessageIdHex: String? = nil
        ) {
            self.groupIdHex = groupIdHex
            let messageId = messageIdHex?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.messageIdHex = messageId?.isEmpty == false ? messageId : nil
            let unreadMessageId = unreadMessageIdHex?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.unreadMessageIdHex = unreadMessageId?.isEmpty == false ? unreadMessageId : nil
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                chatListSearchBar

                Group {
                    if let viewModel {
                        content(viewModel: viewModel)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .trueBlackScaffoldBackground()
            .safeAreaInset(edge: .bottom) {
                if selectionMode, let viewModel {
                    chatSelectionBar(viewModel: viewModel)
                }
            }
            .onChange(of: rowIdsKey) { _, _ in
                selectedChatIds = ChatListSelection.reconcile(selectedChatIds, visibleIds: visibleRowIds)
            }
            .navigationTitle(selectionMode ? "" : "Chats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    settingsButton
                }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 0) {
                        filterMenu
                        Button {
                            showNewChat = true
                        } label: {
                            Image(systemName: "square.and.pencil")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 40, height: 44)
                                .contentShape(.rect)
                        }
                        .accessibilityLabel("New message")
                    }
                }
            }
            // Registered at a stable level so navigation works even when the
            // visible list is empty (e.g. just-created or deep-linked chats).
            .navigationDestination(for: ChatNavigationTarget.self) { target in
                if let viewModel {
                    ChatDestination(
                        target: target,
                        viewModel: viewModel,
                        appState: appState,
                        onGroupLeft: { groupIdHex in
                            viewModel.markGroupLeft(groupIdHex: groupIdHex)
                            path.removeAll { $0.groupIdHex == groupIdHex }
                        },
                        onGroupDeleted: { groupIdHex in
                            viewModel.removeChatListRow(groupIdHex: groupIdHex)
                            path.removeAll { $0.groupIdHex == groupIdHex }
                        }
                    )
                }
            }
            .sheet(isPresented: $showNewChat) {
                NewChatFlowView()
                    .appAppearance()
            }
            .sheet(isPresented: $showSettings) {
                NavigationStack {
                    SettingsView()
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { showSettings = false }
                            }
                        }
                }
                .appAppearance()
            }
            .task(id: subscriptionScope) {
                // Own both creation and binding here so bind() can't be skipped
                // by a nil viewModel: the lazy-creation task could fire after
                // this one, leaving the list permanently empty and unbound.
                let vm = viewModel ?? ChatsListViewModel(appState: appState)
                if viewModel == nil { viewModel = vm }
                await vm.bind(accountRef: appState.activeAccountRef, force: true)
            }
            .onAppear {
                // Reflect messages we sent from a conversation (which emit no
                // event) when returning to the list.
                viewModel?.refreshDisplayProjections()
                Task { await viewModel?.refreshRows() }
            }
            .onChange(of: appState.profileRefreshGeneration) { _, _ in
                viewModel?.refreshDisplayProjections()
            }
            .onChange(of: path.count) { oldCount, count in
                if count > 0 || (oldCount > 0 && count == 0) {
                    dismissSearchKeyboard()
                }
                if oldCount > 0 && count == 0 {
                    viewModel?.refreshDisplayProjections()
                }
            }
        }
        // Warm path: a chat created / deep-linked while the list is on screen.
        .onChange(of: appState.pendingChatId) { _, _ in consumePendingChat() }
        // Cold path: a deep link that set pendingChatId before this appeared.
        .task { consumePendingChat() }
    }

    /// Navigate into a chat requested via `AppState.pendingChatId`, closing any
    /// presenting sheets (composer, account switcher and its nested QR/profile
    /// sheets) so the pushed conversation lands on top.
    ///
    /// Two-phase on purpose: replacing the path in one shot while a deep
    /// stack (details → profile → flow sheet) is tearing down makes
    /// NavigationStack silently restore the old path. Popping to root always
    /// sticks; the clean push follows once the unwind has settled. The
    /// pending id stays set until the final phase so deeper views' unwind
    /// observers are guaranteed to see it.
    private func consumePendingChat() {
        guard let newId = appState.pendingChatId else { return }
        showNewChat = false
        showSettings = false
        dismissSearchKeyboard()
        scope = .active
        path = []
        Task { @MainActor in
            // Cascaded dismissals (flow sheet → profile → details) each take
            // an animation beat, and a push landing mid-cascade gets
            // reverted. No fixed delay wins that race, so push, observe
            // whether the stack kept it, and retry until it sticks.
            for attempt in 0..<8 {
                try? await Task.sleep(nanoseconds: attempt == 0 ? 350_000_000 : 450_000_000)
                guard appState.pendingChatId == newId else { return }
                // Re-read the anchor so a newer jump for the same chat wins.
                let target = ChatNavigationTarget(
                    groupIdHex: newId,
                    messageIdHex: appState.pendingChatMessageIdHex
                )
                path = [target]
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard appState.pendingChatId == newId else { return }
                if path == [target] {
                    appState.clearPendingChat()
                    return
                }
                path = []
            }
            appState.clearPendingChat()
        }
    }

    private func dismissSearchKeyboard() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            searchFocused = false
        }
    }

    // MARK: - Search

    private var chatListSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Search chats", text: $searchText)
                .focused($searchFocused)
                .font(.body)
                .submitLabel(.search)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 40, height: 40)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, searchText.isEmpty ? 12 : 0)
        .frame(minHeight: 40)
        .background(
            Color(.secondarySystemFill),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .background(Color(.systemBackground))
    }

    private var subscriptionScope: SubscriptionScope {
        SubscriptionScope(
            accountRef: appState.activeAccountRef,
            runtimeGeneration: appState.runtimeGeneration,
            isAppSceneActive: appState.isAppSceneActive
        )
    }

    struct SubscriptionScope: Hashable {
        let accountRef: String?
        let runtimeGeneration: Int
        let isAppSceneActive: Bool
    }

    // MARK: - Filter

    private var filterMenu: some View {
        Menu {
            Picker("Filter", selection: $scope) {
                ForEach(ChatScope.allCases, id: \.self) { scope in
                    Label(scope.title, systemImage: scope.systemImage)
                        .tag(scope)
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(scope == .active ? Color.primary : Color.accentColor)
                .frame(width: 40, height: 44)
                .contentShape(.rect)
        }
        .accessibilityLabel("Filter chats")
    }

    // MARK: - List

    @ViewBuilder
    private func content(viewModel: ChatsListViewModel) -> some View {
        if viewModel.isLoading && viewModel.items.isEmpty {
            ProgressView()
        } else if let error = viewModel.loadError {
            ContentUnavailableView(
                "Couldn't load chats",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else {
            let rows = currentRows(viewModel)
            List {
                ForEach(rows) { item in
                    // A plain row (not a Button) keeps tap and long-press
                    // mutually exclusive — a Button's action would also fire
                    // on the release of the long press that just entered
                    // selection mode, instantly clearing it. The explicit
                    // content shape is required: without it the transparent
                    // Spacer gap between a short title/preview and the
                    // timestamp swallows taps.
                    HStack(spacing: 12) {
                        if selectionMode {
                            Image(systemName: selectedChatIds.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedChatIds.contains(item.id) ? Color.accentColor : .secondary)
                                .imageScale(.large)
                                .accessibilityLabel(
                                    selectedChatIds.contains(item.id)
                                        ? L10n.string("Deselect chat")
                                        : L10n.string("Select chat")
                                )
                        }
                        ChatRow(item: item)
                    }
                    .contentShape(.rect)
                    .onTapGesture {
                        if selectionMode {
                            selectedChatIds = ChatListSelection.toggling(selectedChatIds, id: item.id)
                        } else {
                            navigate(to: item)
                        }
                    }
                    .onLongPressGesture {
                        if !selectionMode { selectedChatIds = [item.id] }
                    }
                    .accessibilityAddTraits(.isButton)
                    .swipeActions(edge: .leading) {
                        if !selectionMode { leadingSwipeActions(for: item) }
                    }
                    .swipeActions(edge: .trailing) {
                        if !selectionMode { swipeActions(for: item) }
                    }
                    // Drop the separator above the very first row.
                    .listRowSeparator(
                        item.id == rows.first?.id ? .hidden : .automatic,
                        edges: .top
                    )
                    .listRowSeparatorTint(Color(.separator).opacity(0.35))
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                }
            }
            .listStyle(.plain)
            .compatibleBottomScrollEdgeEffect()
            .overlay {
                if rows.isEmpty { emptyState }
            }
            .refreshable { await viewModel.refreshRows() }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if scope == .archived {
            ContentUnavailableView(
                "No archived chats",
                systemImage: "archivebox",
                description: Text("Swipe a chat to archive it; archived chats stay active but stay out of unread and notification attention.")
            )
        } else if scope == .unread {
            ContentUnavailableView("No unread chats", systemImage: "circle")
        } else {
            EmptyChatsState(action: { showNewChat = true })
        }
    }

    private var selectionMode: Bool { !selectedChatIds.isEmpty }

    private var visibleRows: [ChatsListViewModel.Item] {
        guard let viewModel else { return [] }
        return currentRows(viewModel)
    }

    private var visibleRowIds: Set<String> { Set(visibleRows.map(\.id)) }

    /// Order-stable key so `onChange` fires when the visible set changes
    /// (scope switch, search, row add/remove) and stale selections drop.
    private var rowIdsKey: String { visibleRows.map(\.id).joined(separator: ",") }

    private var selectedItems: [ChatsListViewModel.Item] {
        visibleRows.filter { selectedChatIds.contains($0.id) }
    }

    private func chatSelectionBar(viewModel: ChatsListViewModel) -> some View {
        let items = selectedItems
        let archiveAction = ChatListSelection.bulkArchiveAction(archivedFlags: items.map(\.isArchived))
        let willMute = ChatListSelection.bulkMuteMutes(mutedFlags: items.map(\.isMuted))

        return VStack(spacing: 8) {
            HStack {
                Button("Cancel") { selectedChatIds = [] }
                Spacer()
                Text(L10n.plural("%lld selected", Int64(items.count)))
                    .font(.headline)
                Spacer()
                Button("Select All") { selectedChatIds = ChatListSelection.selectAll(visibleRows.map(\.id)) }
            }

            HStack(spacing: 24) {
                selectionAction(
                    archiveAction == .unarchive ? "Unarchive" : "Archive",
                    systemImage: archiveAction == .unarchive ? "tray.and.arrow.up" : "archivebox"
                ) {
                    let archived = archiveAction == .archive
                    for id in items.map(\.id) {
                        await setArchived(groupIdHex: id, archived: archived)
                    }
                    selectedChatIds = []
                }

                selectionAction(
                    willMute ? "Mute" : "Unmute",
                    systemImage: willMute ? "bell.slash" : "bell"
                ) {
                    for id in items.map(\.id) { setMuted(groupIdHex: id, muted: willMute) }
                    selectedChatIds = []
                }

                // Strictly device-local removal — no leave or admin transfer
                // — deliberately available even for still-member and
                // sole-admin groups. Destructive and unpublished, so it
                // confirms first.
                selectionAction("Delete", systemImage: "trash", role: .destructive) {
                    showBulkDeleteConfirmation = true
                }
                .confirmationDialog(
                    "Remove from this device?",
                    isPresented: $showBulkDeleteConfirmation,
                    titleVisibility: .visible
                ) {
                    Button("Delete", role: .destructive) {
                        Task {
                            for id in items.map(\.id) { await deleteLocal(groupIdHex: id) }
                            selectedChatIds = []
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(.regularMaterial)
    }

    private func selectionAction(
        _ title: LocalizedStringKey,
        systemImage: String,
        role: ButtonRole? = nil,
        perform: @escaping () async -> Void
    ) -> some View {
        Button(role: role) {
            Task { await perform() }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: systemImage).imageScale(.large)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(selectedChatIds.isEmpty)
    }

    private func currentRows(_ viewModel: ChatsListViewModel) -> [ChatsListViewModel.Item] {
        let base: [ChatsListViewModel.Item]
        switch scope {
        case .active:
            base = viewModel.items
        case .archived:
            base = viewModel.archivedItems
        case .unread:
            base = viewModel.items.filter(\.hasUnread)
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        guard !query.isEmpty else { return base }
        return base.filter { $0.searchHaystack.contains(query) }
    }

    private func navigate(to item: ChatsListViewModel.Item) {
        dismissSearchKeyboard()
        path.append(
            ChatNavigationTarget(
                groupIdHex: item.id,
                messageIdHex: item.firstUnreadMessageIdHex,
                unreadMessageIdHex: item.firstUnreadMessageIdHex
            )
        )
    }

    @ViewBuilder
    private func leadingSwipeActions(for item: ChatsListViewModel.Item) -> some View {
        let actions = ChatListSwipeActionsPresentation.leadingActions(isMuted: item.isMuted)

        if actions.contains(.unmute) {
            Button {
                setMuted(groupIdHex: item.id, muted: false)
            } label: {
                Label(L10n.string("Unmute"), systemImage: "bell.fill")
            }
            .tint(.indigo)
        }
        if actions.contains(.mute) {
            Button {
                setMuted(groupIdHex: item.id, muted: true)
            } label: {
                Label(L10n.string("Mute"), systemImage: "bell.slash.fill")
            }
            .tint(.indigo)
        }
    }

    @ViewBuilder
    private func swipeActions(for item: ChatsListViewModel.Item) -> some View {
        let actions = ChatListSwipeActionsPresentation.trailingActions(
            isArchived: item.isArchived,
            selfMembership: item.selfMembership
        )

        if actions.contains(.unarchive) {
            Button {
                Task { await setArchived(groupIdHex: item.id, archived: false) }
            } label: {
                Label("Unarchive", systemImage: "tray.and.arrow.up")
            }
            .tint(.blue)
        }
        if actions.contains(.delete) {
            Button(role: .destructive) {
                Task { await deleteLocal(groupIdHex: item.id) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        if actions.contains(.leave) {
            Button(role: .destructive) {
                Task { await leave(groupIdHex: item.id) }
            } label: {
                Label("Leave", systemImage: "person.crop.circle.badge.minus")
            }
        }
        if actions.contains(.archive) {
            Button {
                Task { await setArchived(groupIdHex: item.id, archived: true) }
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(.gray)
        }
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            if let active = appState.activeAccount {
                AvatarBubble(
                    seed: active.accountIdHex,
                    title: appState.displayName(forAccountIdHex: active.accountIdHex),
                    pictureURL: appState.avatarURL(forAccountIdHex: active.accountIdHex)
                )
                .frame(width: 34, height: 34)
                .shadow(color: .black.opacity(0.18), radius: 2.5, y: 1)
            } else {
                Image(systemName: "person.crop.circle")
            }
        }
        // Plain style so the avatar fills the tap target edge-to-edge instead
        // of sitting inside a glass capsule with padding; the shadow above
        // preserves the raised, tappable affordance.
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }

    @MainActor
    private func deleteLocal(groupIdHex: String) async {
        guard let ref = appState.activeAccountRef else { return }
        do {
            let client = try appState.currentMarmotClient()
            _ = try await client.deleteGroupLocal(
                accountRef: ref,
                groupIdHex: groupIdHex
            )
            viewModel?.removeChatListRow(groupIdHex: groupIdHex)
            Haptics.warning()
        } catch {
            Haptics.error()
            appState.present(.error(L10n.string("Couldn't delete chat"), message: error.localizedDescription))
        }
    }

    @MainActor
    private func leave(groupIdHex: String) async {
        guard let ref = appState.activeAccountRef else { return }
        do {
            let client = try appState.currentMarmotClient()
            let managementState = try await client.groupManagementState(
                accountRef: ref,
                groupIdHex: groupIdHex
            )
            guard GroupManagementPresentation.canLeave(
                state: managementState,
                fallbackIsLastAdmin: false
            ) else {
                Haptics.error()
                appState.present(.error(
                    L10n.string("Couldn't leave chat"),
                    message: GroupManagementPresentation.leaveFooter(
                        state: managementState,
                        fallbackIsLastAdmin: false
                    ) ?? GroupManagementPresentation.leaveHelpMessage(
                        state: managementState,
                        fallbackIsLastAdmin: false
                    )
                ))
                return
            }
            if GroupManagementPresentation.shouldSelfDemoteBeforeLeave(state: managementState) {
                appState.present(.warning(
                    L10n.string("Stepping down before leaving…"),
                    message: L10n.string("Publishing group update.")
                ))
                _ = try await client.selfDemoteAdminDetailed(
                    accountRef: ref,
                    groupIdHex: groupIdHex
                )
            }
            _ = try await client.leaveGroup(
                accountRef: ref,
                groupIdHex: groupIdHex
            )
            // The chats subscription only fires on transport events, not local
            // projection writes, so reflect the inactive local-history state.
            viewModel?.markGroupLeft(groupIdHex: groupIdHex)
            Haptics.warning()
        } catch {
            Haptics.error()
            appState.present(.error(L10n.string("Couldn't leave chat"), message: error.localizedDescription))
        }
    }

    /// Mute is a local, per-device preference: no Marmot publish, so the row
    /// projection is refreshed directly instead of via a group record change.
    @MainActor
    private func setMuted(groupIdHex: String, muted: Bool) {
        guard let accountIdHex = appState.activeAccount?.accountIdHex else { return }
        // Write the tri-state mode, not just the legacy set — an explicit mode
        // outranks the legacy mute on reads, so a bare setMuted would be
        // ignored for any chat the details picker ever touched.
        ChatMuteStore.setNotifyMode(muted ? .nothing : .all, accountIdHex: accountIdHex, groupIdHex: groupIdHex)
        viewModel?.refreshDisplayProjections()
        Haptics.success()
    }

    @MainActor
    private func setArchived(groupIdHex: String, archived: Bool) async {
        guard let ref = appState.activeAccountRef else { return }
        do {
            let client = try appState.currentMarmotClient()
            let updated = try await client.setGroupArchived(
                accountRef: ref,
                groupIdHex: groupIdHex,
                archived: archived
            )
            // The chats subscription only fires on transport events, not local
            // projection writes, so reflect the archive change immediately.
            viewModel?.applyLocalGroupChange(updated)
            Haptics.success()
        } catch {
            Haptics.error()
            appState.present(.error(L10n.string("Couldn't archive chat"), message: error.localizedDescription))
        }
    }
}

/// Resolves a group id to its conversation. A just-created or deep-linked
/// chat may not be in the list yet, so show a spinner until the chats
/// subscription delivers it. Once the row exists, open from the projected row
/// immediately; `ConversationViewModel` refreshes authoritative group details
/// after the local timeline snapshot can render.
private struct ChatDestination: View {
    let target: ChatsListView.ChatNavigationTarget
    let viewModel: ChatsListViewModel
    let appState: AppState
    let onGroupLeft: (String) -> Void
    let onGroupDeleted: (String) -> Void
    @State private var timedOut = false

    private var item: ChatsListViewModel.Item? {
        viewModel.item(groupIdHex: target.groupIdHex)
    }

    var body: some View {
        if let item {
            ConversationView(
                chat: item.projectedGroup,
                accountRef: appState.activeAccountRef,
                initialTitle: item.title,
                initialTargetMessageIdHex: target.messageIdHex,
                initialUnreadMessageIdHex: target.unreadMessageIdHex,
                initialAppState: appState,
                forwardDestinationProvider: {
                    viewModel.forwardDestinations(excludingGroupIdHex: target.groupIdHex)
                },
                onChatListRowUpdated: { viewModel.enqueueChatListRowUpdate($0) },
                onGroupChanged: { viewModel.applyLocalGroupChange($0) },
                onGroupLeft: onGroupLeft,
                onGroupDeleted: onGroupDeleted,
                onDraftChanged: { viewModel.refreshDisplayProjections() }
            )
        } else if timedOut {
            // A slow network can take longer than the spin-wait to deliver the
            // chat-list row. Offer Retry instead of a dead end so the user can
            // wait out another window rather than being told the chat is gone (#71).
            ContentUnavailableView {
                Label("Chat unavailable", systemImage: "questionmark.circle")
            } description: {
                Text("It may still be syncing. Try again in a moment.")
            } actions: {
                Button("Retry") { timedOut = false }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    timedOut = true
                }
        }
    }
}

private struct EmptyChatsState: View {
    let action: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No chats yet", systemImage: "bubble.left.and.bubble.right")
        } description: {
            Text("Search for someone you know, paste their npub, or scan their QR code.")
                .multilineTextAlignment(.center)
        } actions: {
            Button {
                action()
            } label: {
                Label("New Message", systemImage: "square.and.pencil")
                    .padding(.horizontal, 12)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}
