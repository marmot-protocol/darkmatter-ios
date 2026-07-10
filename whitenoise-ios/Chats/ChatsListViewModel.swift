import Foundation
import Observation
import OSLog
import MarmotKit

/// Owns the live list of chats for the currently active account. The list is
/// now driven by Marmot's durable chat-list projection instead of rebuilding
/// previews from account-wide message snapshots on every appearance.
@Observable
@MainActor
final class ChatsListViewModel {
    private static let performanceSignposter = OSSignposter(
        subsystem: "dev.ipf.whitenoise.ios",
        category: "Performance"
    )

    struct Item: Equatable, Identifiable {
        let row: ChatListRowFfi
        let avatarURL: URL?
        let title: String
        let previewText: String?
        let draftPreview: String?
        let searchHaystack: String

        init(
            row: ChatListRowFfi,
            avatarURL: URL?,
            title: String,
            draftText: String? = nil,
            mentionDisplayName: MarkdownMentionResolver? = nil
        ) {
            let previewText = Self.sanitizedPreview(
                from: row.lastMessage,
                mentionDisplayName: mentionDisplayName
            )
            self.row = row
            self.avatarURL = avatarURL
            self.title = title
            self.previewText = previewText
            self.draftPreview = ConversationDraftPreview.text(from: draftText)
            self.searchHaystack = Self.makeSearchHaystack(
                title: title,
                previewText: previewText,
                draftPreview: self.draftPreview
            )
        }

        var id: String { row.groupIdHex }
        var unreadCount: UInt64 { row.unreadCount }
        var hasUnread: Bool { row.hasUnread }
        var unreadMentionCount: UInt64 { row.unreadMentionCount }
        var hasUnreadMention: Bool { row.unreadMention || row.unreadMentionCount > 0 }
        var isArchived: Bool { row.archived }
        var selfMembership: SelfMembershipFfi { row.selfMembership }
        var isActiveMember: Bool {
            GroupManagementPresentation.isActiveChatListMember(row.selfMembership)
        }
        var firstUnreadMessageIdHex: String? { row.firstUnreadMessageIdHex }
        var lastMessage: ChatListMessagePreviewFfi? { row.lastMessage }
        var projectedGroup: AppGroupRecordFfi {
            AppGroupRecordFfi(
                groupIdHex: row.groupIdHex,
                endpoint: "",
                name: ContentSanitizer.groupName(row.groupName) ?? title,
                description: "",
                admins: [],
                relays: [],
                nostrGroupIdHex: "",
                avatarUrl: row.avatarUrl,
                avatarDim: nil,
                avatarThumbhash: nil,
                encryptedMedia: AppGroupEncryptedMediaComponentFfi(
                    componentId: 0,
                    component: "",
                    required: false,
                    mediaFormat: "",
                    allowedLocatorKinds: [],
                    defaultBlobEndpoints: []
                ),
                archived: row.archived,
                pendingConfirmation: row.pendingConfirmation,
                selfMembership: row.selfMembership,
                welcomerAccountIdHex: nil,
                viaWelcomeMessageIdHex: nil
            )
        }

        static func sanitizedTitle(for row: ChatListRowFfi) -> String {
            if let name = ContentSanitizer.groupName(row.groupName) { return name }
            if let name = ContentSanitizer.groupName(row.title) { return name }
            return IdentityFormatter.short(row.groupIdHex)
        }

        private static func sanitizedPreview(
            from preview: ChatListMessagePreviewFfi?,
            mentionDisplayName: MarkdownMentionResolver?
        ) -> String? {
            preview.flatMap {
                ContentSanitizer.singleLine(
                    MessagePreview.body($0, mentionDisplayName: mentionDisplayName),
                    maxLength: 140
                )
            }
        }

        private static func makeSearchHaystack(
            title: String,
            previewText: String?,
            draftPreview: String?
        ) -> String {
            [title, previewText, draftPreview]
                .compactMap { $0 }
                .joined(separator: " ")
                .localizedLowercase
        }
    }

    private(set) var items: [Item] = []
    private(set) var archivedItems: [Item] = []
    private(set) var isLoading: Bool = false
    private(set) var loadError: String?

    private weak var appState: AppState?
    @ObservationIgnored private let draftStore: ConversationDraftStore
    private var chatListTask: Task<Void, Never>?
    private var chatListTaskID: UUID?
    private var avatarURLTask: Task<Void, Never>?
    private var avatarEnrichmentTaskID: UUID?
    private var pendingChatListUpdateTask: Task<Void, Never>?
    private var currentAccount: String?
    private var rowByGroupId: [String: ChatListRowFfi] = [:]
    private var itemByGroupId: [String: Item] = [:]
    private var pendingChatListRowsByGroupId: [String: ChatListRowFfi] = [:]
    private var avatarURLByGroupId: [String: String] = [:]
    private var avatarURLLoadedGroupIds: Set<String> = []
    private var pendingAvatarURLRefreshGroupIds: Set<String> = []
    private var groupDetailsCache: [String: GroupDetailsFfi] = [:]
    private var groupDetailsLoadedGroupIds: Set<String> = []
    private var pendingGroupDetailsRefreshGroupIds: Set<String> = []

    private static let chatListUpdateCoalescingDelayNanoseconds: UInt64 = 16_000_000
    private static let liveSubscriptionInitialRetryDelayNanoseconds: UInt64 = 500_000_000
    private static let liveSubscriptionMaximumRetryDelayNanoseconds: UInt64 = 8_000_000_000
    private static let rowEnrichmentRetryDelayNanoseconds: UInt64 = 1_000_000_000

    #if DEBUG
    @ObservationIgnored var mentionDisplayNameForTesting: MarkdownMentionResolver?
    @ObservationIgnored private(set) var publishedItemsMutationCountForTesting = 0
    #endif

    init(appState: AppState) {
        self.appState = appState
        self.draftStore = appState.conversationDraftStore
    }

    isolated deinit {
        chatListTask?.cancel()
        avatarURLTask?.cancel()
        pendingChatListUpdateTask?.cancel()
    }

    /// Begin (or rebind, when `accountRef` changes) the projected chat-list
    /// subscription.
    func bind(accountRef: String?, force: Bool = false) async {
        if currentAccount == accountRef, !force { return }
        chatListTask?.cancel()
        chatListTask = nil
        chatListTaskID = nil
        avatarURLTask?.cancel()
        avatarURLTask = nil
        avatarEnrichmentTaskID = nil
        pendingChatListUpdateTask?.cancel()
        pendingChatListUpdateTask = nil
        if currentAccount != accountRef {
            rowByGroupId = [:]
            itemByGroupId = [:]
            items = []
            archivedItems = []
            pendingChatListRowsByGroupId = [:]
            avatarURLByGroupId = [:]
            avatarURLLoadedGroupIds = []
            pendingAvatarURLRefreshGroupIds = []
            groupDetailsCache = [:]
            groupDetailsLoadedGroupIds = []
            pendingGroupDetailsRefreshGroupIds = []
        }
        loadError = nil

        guard let accountRef else {
            currentAccount = nil
            return
        }
        await draftStore.loadIfNeeded()
        guard !Task.isCancelled else { return }
        guard let appState, appState.canUseRuntimeForForegroundWork else { return }
        currentAccount = accountRef
        isLoading = true
        defer {
            if currentAccount == accountRef {
                isLoading = false
            }
        }
        do {
            let snapshot = try await appState.currentMarmotClient().chatList(
                accountRef: accountRef,
                includeArchived: true
            )
            guard currentAccount == accountRef else { return }
            applyChatListSnapshot(snapshot)
        } catch is CancellationError {
            return
        } catch {
            guard currentAccount == accountRef else { return }
            loadError = error.localizedDescription
        }
        guard currentAccount == accountRef else { return }
        startLiveUpdates(accountRef: accountRef)
    }

    private func startLiveUpdates(accountRef: String) {
        guard let appState else { return }
        let taskID = UUID()
        chatListTaskID = taskID
        chatListTask = Task { @MainActor [weak self, weak appState] in
            defer { self?.finishChatListTask(taskID: taskID) }
            var retryDelay = Self.liveSubscriptionInitialRetryDelayNanoseconds
            while !Task.isCancelled {
                do {
                    guard let appState, appState.canUseRuntimeForForegroundWork else { return }
                    let client = try appState.currentMarmotClient()
                    let chatListSub = try await client.subscribeChatList(
                        accountRef: accountRef,
                        includeArchived: true
                    )
                    guard !Task.isCancelled,
                          self?.ownsChatListTask(taskID: taskID, accountRef: accountRef) == true
                    else { return }
                    let snapshot = await client.chatListSubscriptionSnapshot(chatListSub)
                    guard !Task.isCancelled,
                          appState.canUseRuntimeForForegroundWork,
                          self?.ownsChatListTask(taskID: taskID, accountRef: accountRef) == true
                    else { return }
                    self?.loadError = nil
                    self?.applyChatListSnapshot(snapshot)

                    for await update in SubscriptionDriver.chatListUpdates(chatListSub) {
                        guard !Task.isCancelled,
                              appState.canUseRuntimeForForegroundWork,
                              self?.ownsChatListTask(taskID: taskID, accountRef: accountRef) == true
                        else { return }
                        retryDelay = Self.liveSubscriptionInitialRetryDelayNanoseconds
                        self?.applyChatListUpdate(update)
                    }
                } catch is CancellationError {
                    return
                } catch {
                    guard !Task.isCancelled,
                          appState?.canUseRuntimeForForegroundWork == true,
                          self?.ownsChatListTask(taskID: taskID, accountRef: accountRef) == true
                    else { return }
                    if self?.rowByGroupId.isEmpty == true {
                        self?.loadError = error.localizedDescription
                    }
                }
                guard !Task.isCancelled,
                      appState?.canUseRuntimeForForegroundWork == true,
                      self?.ownsChatListTask(taskID: taskID, accountRef: accountRef) == true
                else { return }
                do {
                    try await Task.sleep(nanoseconds: retryDelay)
                } catch {
                    return
                }
                retryDelay = Self.nextLiveSubscriptionRetryDelay(after: retryDelay)
            }
        }
    }

    /// Re-pull the durable rows from local storage. This keeps pull-to-refresh
    /// and list reappearance useful without doing an account-wide message scan.
    func refreshRows() async {
        guard let accountRef = currentAccount,
              let appState,
              appState.canUseRuntimeForForegroundWork
        else { return }
        await draftStore.loadIfNeeded()
        do {
            let snapshot = try await appState.currentMarmotClient().chatList(
                accountRef: accountRef,
                includeArchived: true
            )
            guard currentAccount == accountRef else { return }
            applyChatListSnapshot(snapshot)
        } catch is CancellationError {
            return
        } catch {
            // Non-fatal: subscription updates remain authoritative.
        }
    }

    /// O(1) lookup for a chat-list item by its group id, backed by the
    /// id-keyed `itemByGroupId` map. Views that resolve a single row by id
    /// (e.g. deep-link destinations) should use this instead of scanning the
    /// published `items`/`archivedItems` arrays in `body`.
    func item(groupIdHex: String) -> Item? {
        itemByGroupId[groupIdHex]
    }

    /// Forwarding should use the same live, enriched projection as the chat
    /// list so newly-arrived rows and resolved direct-chat names are preserved.
    func forwardDestinations(excludingGroupIdHex currentGroupIdHex: String) -> [MessageForwardDestination] {
        MessageForwardDestinationPresentation.destinations(
            from: Array(itemByGroupId.values),
            excludingGroupIdHex: currentGroupIdHex
        )
    }

    func applyChatListSnapshot(_ snapshot: [ChatListRowFfi]) {
        pendingChatListRowsByGroupId = [:]
        let previousRows = rowByGroupId
        let previousItems = itemByGroupId
        var nextRows: [String: ChatListRowFfi] = [:]
        var nextItems: [String: Item] = [:]
        var changed = false
        for row in snapshot {
            updateCachedGroupDetails(with: row)
            let item = makeItem(for: row)
            nextRows[row.groupIdHex] = row
            nextItems[row.groupIdHex] = item
            if previousRows[row.groupIdHex] != row || previousItems[row.groupIdHex] != item {
                changed = true
            }
        }
        if Set(previousRows.keys) != Set(nextRows.keys) {
            changed = true
        }
        rowByGroupId = nextRows
        itemByGroupId = nextItems
        pruneEnrichmentCaches(toSurviving: Set(rowByGroupId.keys))
        if changed {
            publishItems()
        }
        scheduleRowEnrichment(for: snapshot)
    }

    /// Intersect the parallel enrichment caches/sets down to the surviving
    /// group-id key set after a full snapshot rebuild. A snapshot never calls
    /// `removeChatListRow`, so groups that drop out of the list between
    /// snapshots would otherwise strand entries in these collections for the
    /// lifetime of the account binding. Mirrors `removeChatListRow`'s per-group
    /// cleanup for every group absent from the snapshot.
    private func pruneEnrichmentCaches(toSurviving surviving: Set<String>) {
        groupDetailsCache = Self.intersecting(groupDetailsCache, with: surviving)
        avatarURLByGroupId = Self.intersecting(avatarURLByGroupId, with: surviving)
        groupDetailsLoadedGroupIds = Self.intersecting(groupDetailsLoadedGroupIds, with: surviving)
        avatarURLLoadedGroupIds = Self.intersecting(avatarURLLoadedGroupIds, with: surviving)
        pendingAvatarURLRefreshGroupIds = Self.intersecting(pendingAvatarURLRefreshGroupIds, with: surviving)
        pendingGroupDetailsRefreshGroupIds = Self.intersecting(pendingGroupDetailsRefreshGroupIds, with: surviving)
    }

    /// Pure helper: keep only the dictionary entries whose key survives.
    static func intersecting<Value>(
        _ cache: [String: Value],
        with surviving: Set<String>
    ) -> [String: Value] {
        cache.filter { surviving.contains($0.key) }
    }

    /// Pure helper: keep only the set members that survive.
    static func intersecting(
        _ ids: Set<String>,
        with surviving: Set<String>
    ) -> Set<String> {
        ids.intersection(surviving)
    }

    func applyChatListRow(_ row: ChatListRowFfi) {
        pendingChatListRowsByGroupId[row.groupIdHex] = nil
        if storeRow(row) {
            publishItems()
        }
        scheduleRowEnrichment(for: [row])
    }

    func enqueueChatListRowUpdate(_ row: ChatListRowFfi) {
        enqueueChatListRow(row)
    }

    func applyChatListUpdate(_ update: ChatListSubscriptionUpdateFfi) {
        switch update {
        case .row(_, let row):
            enqueueChatListRow(row)
        case .removeRow(_, let groupIdHex):
            removeChatListRow(groupIdHex: groupIdHex)
        }
    }

    func removeChatListRow(groupIdHex: String) {
        pendingChatListRowsByGroupId[groupIdHex] = nil
        let hadPublishedRow = rowByGroupId[groupIdHex] != nil || itemByGroupId[groupIdHex] != nil
        rowByGroupId[groupIdHex] = nil
        itemByGroupId[groupIdHex] = nil
        avatarURLByGroupId[groupIdHex] = nil
        avatarURLLoadedGroupIds.remove(groupIdHex)
        pendingAvatarURLRefreshGroupIds.remove(groupIdHex)
        groupDetailsCache[groupIdHex] = nil
        groupDetailsLoadedGroupIds.remove(groupIdHex)
        pendingGroupDetailsRefreshGroupIds.remove(groupIdHex)
        if let currentAccount {
            draftStore.removeDraft(accountRef: currentAccount, groupIdHex: groupIdHex)
        }
        if hadPublishedRow {
            publishItems()
        }
    }

    func markGroupLeft(groupIdHex: String) {
        guard var row = rowByGroupId[groupIdHex] else { return }
        if let currentAccount {
            draftStore.removeDraft(accountRef: currentAccount, groupIdHex: groupIdHex)
        }
        row.selfMembership = .left
        row.pendingConfirmation = false
        if storeRow(row) {
            publishItems()
        }
    }

    /// Reflect a locally-produced group change (e.g. an archive toggle) right
    /// away. Some local projection writes return group records rather than
    /// chat-list rows, so fold the changed fields into the current row.
    func applyLocalGroupChange(_ record: AppGroupRecordFfi) {
        pendingChatListRowsByGroupId[record.groupIdHex] = nil
        var row = rowByGroupId[record.groupIdHex] ?? Self.row(from: record)
        row.archived = record.archived
        row.pendingConfirmation = record.pendingConfirmation
        row.selfMembership = record.selfMembership
        row.groupName = record.name
        row.avatarUrl = record.avatarUrl
        if let name = ContentSanitizer.groupName(record.name) {
            row.title = name
        }
        avatarURLByGroupId[record.groupIdHex] = record.avatarUrl
        avatarURLLoadedGroupIds.insert(record.groupIdHex)
        pendingAvatarURLRefreshGroupIds.remove(record.groupIdHex)
        updateCachedGroupDetails(with: record)
        if storeRow(row) {
            publishItems()
        }
    }

    private func enqueueChatListRow(_ row: ChatListRowFfi) {
        pendingChatListRowsByGroupId[row.groupIdHex] = row
        guard pendingChatListUpdateTask == nil else { return }
        pendingChatListUpdateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.chatListUpdateCoalescingDelayNanoseconds)
            guard !Task.isCancelled else { return }
            self?.flushPendingChatListUpdates()
        }
    }

    private func flushPendingChatListUpdates() {
        pendingChatListUpdateTask = nil
        let pendingRows = Array(pendingChatListRowsByGroupId.values)
        pendingChatListRowsByGroupId = [:]
        guard !pendingRows.isEmpty else { return }
        var changed = false
        for row in pendingRows {
            changed = storeRow(row) || changed
        }
        if changed {
            publishItems()
        }
        scheduleRowEnrichment(for: pendingRows)
    }

    @discardableResult
    private func storeRow(_ row: ChatListRowFfi) -> Bool {
        updateCachedGroupDetails(with: row)
        let item = makeItem(for: row)
        let changed = itemByGroupId[row.groupIdHex] != item
        rowByGroupId[row.groupIdHex] = row
        itemByGroupId[row.groupIdHex] = item
        return changed
    }

    func refreshDisplayProjections() {
        guard !rowByGroupId.isEmpty else { return }
        var changed = false
        for (groupId, row) in rowByGroupId {
            let item = makeItem(for: row)
            if itemByGroupId[groupId] != item {
                itemByGroupId[groupId] = item
                changed = true
            }
        }
        if changed {
            publishItems()
        }
    }

    private func makeItem(for row: ChatListRowFfi) -> Item {
        let display = display(for: row, details: groupDetailsCache[row.groupIdHex])
        let draftAccountRef = currentAccount ?? appState?.activeAccountRef
        return Item(
            row: row,
            avatarURL: display.avatarURL,
            title: display.title,
            draftText: draftAccountRef.flatMap {
                draftStore.draft(accountRef: $0, groupIdHex: row.groupIdHex)
            },
            mentionDisplayName: { [weak appState] entity in
                #if DEBUG
                if let name = self.mentionDisplayNameForTesting?(entity) {
                    return name
                }
                #endif
                return appState?.mentionDisplayName(for: entity)
            }
        )
    }

    private func updateCachedGroupDetails(with row: ChatListRowFfi) {
        guard var details = groupDetailsCache[row.groupIdHex] else { return }
        var group = details.group
        var changed = false
        if group.name != row.groupName {
            group.name = row.groupName
            changed = true
        }
        if group.avatarUrl != row.avatarUrl {
            group.avatarUrl = row.avatarUrl
            changed = true
        }
        guard changed else { return }
        details.group = group
        groupDetailsCache[row.groupIdHex] = details
        avatarURLByGroupId[row.groupIdHex] = row.avatarUrl
    }

    private func updateCachedGroupDetails(with group: AppGroupRecordFfi) {
        guard var details = groupDetailsCache[group.groupIdHex] else { return }
        details.group = group
        groupDetailsCache[group.groupIdHex] = details
    }

    private func display(
        for row: ChatListRowFfi,
        details: GroupDetailsFfi?
    ) -> (title: String, avatarURL: URL?) {
        let fallbackAvatarURL = ContentSanitizer.imageURL(row.avatarUrl ?? avatarURLByGroupId[row.groupIdHex])
        guard let details, let appState else {
            return (title: Item.sanitizedTitle(for: row), avatarURL: fallbackAvatarURL)
        }

        let groupDisplay = Self.groupDisplay(for: details, appState: appState)
        return (
            title: GroupDisplay.title(for: groupDisplay, appState: appState),
            avatarURL: GroupDisplay.avatarURL(for: groupDisplay, appState: appState) ?? fallbackAvatarURL
        )
    }

    static func nextLiveSubscriptionRetryDelay(after delay: UInt64) -> UInt64 {
        guard delay < liveSubscriptionMaximumRetryDelayNanoseconds else {
            return liveSubscriptionMaximumRetryDelayNanoseconds
        }
        let doubled = delay.multipliedReportingOverflow(by: 2)
        guard !doubled.overflow else { return liveSubscriptionMaximumRetryDelayNanoseconds }
        return min(doubled.partialValue, liveSubscriptionMaximumRetryDelayNanoseconds)
    }

    static func displayTitle(
        for row: ChatListRowFfi,
        details: GroupDetailsFfi?,
        appState: AppState?
    ) -> String {
        guard let details, let appState else { return Item.sanitizedTitle(for: row) }
        let groupDisplay = groupDisplay(for: details, appState: appState)
        return GroupDisplay.title(for: groupDisplay, appState: appState)
    }

    private static func groupDisplay(
        for details: GroupDetailsFfi,
        appState: AppState
    ) -> GroupDisplay.Resolved {
        let members = memberRecords(from: details)
        let otherMember = GroupDisplay.otherMemberAccount(
            in: members,
            myAccountId: appState.activeAccount?.accountIdHex
        )
        return GroupDisplay.resolve(
            group: details.group,
            otherMember: otherMember,
            memberCount: members.count
        )
    }

    static func memberRecords(from details: GroupDetailsFfi) -> [AppGroupMemberRecordFfi] {
        details.members.map {
            AppGroupMemberRecordFfi(
                memberIdHex: $0.memberIdHex,
                account: $0.account,
                local: $0.local
            )
        }
    }

    private static func rowNeedsDisplayEnrichment(_ row: ChatListRowFfi) -> Bool {
        ContentSanitizer.groupName(row.groupName) == nil
    }

    @discardableResult
    private func publishItems() -> Bool {
        let signpost = Self.performanceSignposter.beginInterval("ChatsListViewModel.publishItems")
        defer { Self.performanceSignposter.endInterval("ChatsListViewModel.publishItems", signpost) }

        let all = Array(itemByGroupId.values)
        let nextItems = all.filter { !$0.row.archived }.sorted(by: Self.sortRule)
        let nextArchivedItems = all.filter { $0.row.archived }.sorted(by: Self.sortRule)
        guard items != nextItems || archivedItems != nextArchivedItems else { return false }
        items = nextItems
        archivedItems = nextArchivedItems
        #if DEBUG
        publishedItemsMutationCountForTesting += 1
        #endif
        updateActiveAccountUnreadSummary(rows: all.map(\.row))
        return true
    }

    private func updateActiveAccountUnreadSummary(rows: [ChatListRowFfi]) {
        guard
            let accountRef = currentAccount,
            let appState,
            let account = appState.accounts.first(where: { $0.label == accountRef })
        else { return }

        appState.updateAccountUnreadSummary(
            accountIdHex: account.accountIdHex,
            chatListRows: rows
        )
    }

    private func scheduleRowEnrichment(for rows: [ChatListRowFfi]) {
        guard let accountRef = currentAccount, let appState else { return }
        let groupIds = rows.compactMap { row -> String? in
            let needsAvatar = row.avatarUrl == nil && !avatarURLLoadedGroupIds.contains(row.groupIdHex)
            let needsDisplay = Self.rowNeedsDisplayEnrichment(row)
                && !groupDetailsLoadedGroupIds.contains(row.groupIdHex)
            guard needsAvatar || needsDisplay else { return nil }
            return row.groupIdHex
        }
        guard !groupIds.isEmpty else { return }

        pendingAvatarURLRefreshGroupIds.formUnion(
            groupIds.filter { groupId in
                rowByGroupId[groupId]?.avatarUrl == nil
                    && !avatarURLLoadedGroupIds.contains(groupId)
            }
        )
        pendingGroupDetailsRefreshGroupIds.formUnion(
            groupIds.filter { groupId in
                guard let row = rowByGroupId[groupId] else { return false }
                return Self.rowNeedsDisplayEnrichment(row)
                    && !groupDetailsLoadedGroupIds.contains(groupId)
            }
        )
        guard avatarURLTask == nil else { return }
        let taskID = UUID()
        avatarEnrichmentTaskID = taskID
        avatarURLTask = Task { @MainActor [weak self, weak appState] in
            defer { self?.finishAvatarEnrichmentTask(taskID: taskID) }
            guard let self, let appState else { return }
            while !Task.isCancelled, self.currentAccount == accountRef {
                let avatarGroupIds = self.pendingAvatarURLRefreshGroupIds
                let displayGroupIds = self.pendingGroupDetailsRefreshGroupIds
                self.pendingAvatarURLRefreshGroupIds = []
                self.pendingGroupDetailsRefreshGroupIds = []
                let groupIds = Array(avatarGroupIds.union(displayGroupIds))
                guard !groupIds.isEmpty else { break }

                var changed = false
                var failedAvatarGroupIds: Set<String> = []
                var failedDisplayGroupIds: Set<String> = []
                for groupId in groupIds where !Task.isCancelled {
                    let details: GroupDetailsFfi
                    do {
                        let client = try appState.currentMarmotClient()
                        details = try await client.groupDetails(
                            accountRef: accountRef,
                            groupIdHex: groupId
                        )
                    } catch is CancellationError {
                        return
                    } catch {
                        if avatarGroupIds.contains(groupId) {
                            failedAvatarGroupIds.insert(groupId)
                        }
                        if displayGroupIds.contains(groupId) {
                            failedDisplayGroupIds.insert(groupId)
                        }
                        continue
                    }
                    guard self.ownsAvatarEnrichmentTask(taskID: taskID, accountRef: accountRef) else { return }

                    // `groupDetails` is a suspension point: a full-snapshot
                    // replace (`applyChatListSnapshot`) can run during the await
                    // and prune this group out of `rowByGroupId` and the
                    // enrichment caches. Skip writing any cache/loaded-set state
                    // for a group that no longer survives so in-flight
                    // enrichment cannot strand entries for a removed row.
                    guard let row = self.rowByGroupId[groupId] else { continue }

                    self.groupDetailsCache[groupId] = details
                    self.groupDetailsLoadedGroupIds.insert(groupId)
                    if Self.rowNeedsDisplayEnrichment(row) {
                        let members = Self.memberRecords(from: details)
                        if members.count == 2,
                           let other = GroupDisplay.otherMemberAccount(
                               in: members,
                               myAccountId: appState.activeAccount?.accountIdHex
                           ) {
                            appState.warmProfileProjection(
                                forAccountIdHex: other,
                                refreshAfterLoad: true
                            )
                        }
                    }

                    if row.avatarUrl == nil {
                        self.avatarURLLoadedGroupIds.insert(groupId)
                        if let avatarUrl = details.group.avatarUrl {
                            self.avatarURLByGroupId[groupId] = avatarUrl
                        }
                    }

                    let item = self.makeItem(for: row)
                    if self.itemByGroupId[groupId] != item {
                        self.itemByGroupId[groupId] = item
                        changed = true
                    }
                }
                guard !Task.isCancelled, self.ownsAvatarEnrichmentTask(taskID: taskID, accountRef: accountRef) else { break }
                self.pendingAvatarURLRefreshGroupIds.formUnion(
                    failedAvatarGroupIds.filter { self.rowByGroupId[$0] != nil }
                )
                self.pendingGroupDetailsRefreshGroupIds.formUnion(
                    failedDisplayGroupIds.filter { self.rowByGroupId[$0] != nil }
                )
                if changed {
                    self.publishItems()
                }
                if !failedAvatarGroupIds.isEmpty || !failedDisplayGroupIds.isEmpty {
                    do {
                        try await Task.sleep(nanoseconds: Self.rowEnrichmentRetryDelayNanoseconds)
                    } catch {
                        return
                    }
                }
            }
        }
    }

    private func ownsChatListTask(taskID: UUID, accountRef: String) -> Bool {
        currentAccount == accountRef && chatListTaskID == taskID
    }

    private func finishChatListTask(taskID: UUID) {
        guard chatListTaskID == taskID else { return }
        chatListTask = nil
        chatListTaskID = nil
    }

    private func ownsAvatarEnrichmentTask(taskID: UUID, accountRef: String) -> Bool {
        currentAccount == accountRef && avatarEnrichmentTaskID == taskID
    }

    private func finishAvatarEnrichmentTask(taskID: UUID) {
        guard avatarEnrichmentTaskID == taskID else { return }
        avatarURLTask = nil
        avatarEnrichmentTaskID = nil
    }

    #if DEBUG
    func seedGroupDetailsCacheForTesting(_ details: GroupDetailsFfi) {
        let groupId = details.group.groupIdHex
        groupDetailsCache[groupId] = details
        groupDetailsLoadedGroupIds.insert(groupId)
        if let avatarUrl = details.group.avatarUrl {
            avatarURLByGroupId[groupId] = avatarUrl
            avatarURLLoadedGroupIds.insert(groupId)
        }
        if let row = rowByGroupId[groupId] {
            let item = makeItem(for: row)
            if itemByGroupId[groupId] != item {
                itemByGroupId[groupId] = item
                publishItems()
            }
        }
    }

    var avatarEnrichmentTaskIDForTesting: UUID? { avatarEnrichmentTaskID }

    func installAvatarEnrichmentTaskForTesting(taskID: UUID) {
        avatarURLTask?.cancel()
        avatarURLTask = Task {}
        avatarEnrichmentTaskID = taskID
    }

    func finishAvatarEnrichmentTaskForTesting(taskID: UUID) {
        finishAvatarEnrichmentTask(taskID: taskID)
    }
    #endif

    /// Newest projected activity first; rows without messages fall back to the
    /// projection update time, then title.
    private static let sortRule: (Item, Item) -> Bool = { a, b in
        switch (a.row.lastMessage?.timelineAt, b.row.lastMessage?.timelineAt) {
        case let (ta?, tb?) where ta != tb:
            return ta > tb
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        default:
            if a.row.updatedAt != b.row.updatedAt {
                return a.row.updatedAt > b.row.updatedAt
            }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    private static func row(from group: AppGroupRecordFfi) -> ChatListRowFfi {
        let title = ContentSanitizer.groupName(group.name) ?? IdentityFormatter.short(group.groupIdHex)
        return ChatListRowFfi(
            groupIdHex: group.groupIdHex,
            archived: group.archived,
            pendingConfirmation: group.pendingConfirmation,
            title: title,
            groupName: group.name,
            avatarUrl: group.avatarUrl,
            avatar: nil,
            lastMessage: nil,
            unreadCount: 0,
            hasUnread: false,
            unreadMentionCount: 0,
            unreadMention: false,
            firstUnreadMessageIdHex: nil,
            lastReadMessageIdHex: nil,
            lastReadTimelineAt: nil,
            updatedAt: UInt64(Date().timeIntervalSince1970),
            selfMembership: group.selfMembership
        )
    }
}
