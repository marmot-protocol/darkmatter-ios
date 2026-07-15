import SwiftUI
import UIKit
import MarmotKit

enum GroupDetailsConfirmation: Identifiable {
    case leave
    case deleteLocal
    case remove(GroupMemberDetailsFfi)
    case selfDemote

    var id: String {
        switch self {
        case .leave:
            return "leave"
        case .deleteLocal:
            return "delete-local"
        case .remove(let member):
            return "remove-\(member.memberIdHex)"
        case .selfDemote:
            return "self-demote"
        }
    }
}

/// Conversation inspector. Direct messages get contact-centric sections
/// (identity, shared media, privacy, shared groups); groups get the full
/// membership surface (identity, actions, media, settings, members,
/// technical details, destructive actions). Mutations, confirmations, and
/// developer diagnostics are shared between the two.
struct GroupDetailsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: ConversationViewModel
    var onGroupChanged: (AppGroupRecordFfi) -> Void = { _ in }
    var onGroupLeft: (String) -> Void = { _ in }
    var onGroupDeleted: (String) -> Void = { _ in }

    @State private var model = GroupDetailsViewModel()
    @State private var sharedMediaGallery: MessageMediaGallery?
    /// Pushes the tapped member's profile within this details navigation stack.
    @State private var memberProfileNpub: String?
    @State private var memberSearchText = ""
    @State private var membersExpanded = false
    @State private var showTechnicalDetails = false

    private var isAdmin: Bool { viewModel.isSelfAdmin }
    private var isDirectMessage: Bool { viewModel.groupDisplay.isDirectMessage }
    private var memberCount: Int {
        viewModel.groupMemberDetails.isEmpty ? viewModel.members.count : viewModel.groupMemberDetails.count
    }

    var body: some View {
        @Bindable var model = model
        // @ObservationIgnored, so this never triggers a re-render; it guarantees
        // the model's conversation/onGroupChanged are set before any method runs.
        model.conversation = viewModel
        model.onGroupChanged = onGroupChanged
        model.onGroupLeft = onGroupLeft
        model.onGroupDeleted = onGroupDeleted
        return Form {
            if isDirectMessage {
                DirectChatDetailsContent(
                    viewModel: viewModel,
                    model: model,
                    onSearch: openConversationSearch,
                    onOpenChat: openChat,
                    onLoadMedia: mediaLoader,
                    onOpenGallery: { sharedMediaGallery = $0 }
                )
            } else {
                identityHeaderSection
                groupActionsRowSection
                sharedMediaSection
                groupSettingsSection
                membersSection
                technicalDetailsSection
                destructiveActionsSection
            }

            if appState.developerMode {
                transcriptExportSection
                developerSection
                pushNotificationsDeveloperSection
            }

            if let actionError = model.actionError {
                Section {
                    Label(actionError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(isDirectMessage ? "Contact Info" : "Group Info")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $memberProfileNpub) { npub in
            ProfileView(npub: npub)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
            if !isDirectMessage && isAdmin {
                ToolbarItem(placement: .topBarTrailing) {
                    editMenu
                }
            }
        }
        .sheet(isPresented: $model.showAddMembers) {
            AddMembersSheet(
                normalize: { try await appState.currentMarmotClient().normalizeMemberRef(memberRef: $0) },
                onSubmit: { refs in try await model.invite(refs: refs, using: appState) },
                excludedAccountIds: AddMembersPresentation.excludedInviteAccountIds(
                    activeAccountIdHex: appState.activeAccount?.accountIdHex,
                    members: viewModel.members,
                    groupMemberDetails: viewModel.groupMemberDetails
                ),
                excludedMemberMessage: AddMembersPresentation.existingMemberMessage
            )
            .appAppearance()
        }
        .sheet(isPresented: $model.showGroupImageEditor) {
            GroupImageURLSheet(initialURL: viewModel.group.avatarUrl) { url in
                try await model.updateGroupImage(url: url, using: appState)
            }
            .appAppearance()
        }
        .sheet(isPresented: $model.showRetentionEditor) {
            GroupRetentionEditorSheet(
                currentSeconds: viewModel.group.disappearingMessageSecs,
                onSubmit: GroupRetentionSubmitter { seconds in
                    await model.updateRetention(seconds: seconds, using: appState)
                }
            )
            .appAppearance()
        }
        .sheet(isPresented: $model.showDescriptionEditor) {
            NavigationStack {
                Form {
                    Section {
                        TextField(
                            "Description",
                            text: $model.descriptionDraft,
                            axis: .vertical
                        )
                        .lineLimit(4...8)
                    } footer: {
                        Text("Everyone in the group will see this description. Leave it blank to remove it.")
                    }
                }
                .navigationTitle("Edit Description")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { model.showDescriptionEditor = false }
                            .disabled(model.membershipActionInFlight)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            Task {
                                if await model.updateDescription(using: appState) {
                                    model.showDescriptionEditor = false
                                }
                            }
                        }
                        .disabled(model.membershipActionInFlight)
                    }
                }
                .interactiveDismissDisabled(model.membershipActionInFlight)
            }
            .appAppearance()
        }
        .alert("Group name", isPresented: $model.showRename) {
            TextField("Group name", text: $model.renameDraft)
            Button("Save") { Task { await model.rename(using: appState) } }
                .disabled(Self.validatedGroupName(model.renameDraft) == nil)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Everyone in the group will see the new name.")
        }
        .fullScreenCover(item: $model.pendingConfirmation) { confirmation in
            fullScreenConfirmation(for: confirmation)
                .appAppearance()
        }
        .fullScreenCover(item: $sharedMediaGallery) { gallery in
            MessageMediaFullscreenGalleryView(
                gallery: gallery,
                onLoadMedia: mediaLoader,
                onDismiss: { sharedMediaGallery = nil }
            )
        }
        .alert(model.actionHelp?.title ?? "", isPresented: actionHelpBinding) {
            Button("OK", role: .cancel) { model.actionHelp = nil }
        } message: {
            Text(model.actionHelp?.message ?? "")
        }
        .alert(
            "Export failed",
            isPresented: Binding(
                get: { model.transcriptExportError != nil },
                set: { if !$0 { model.transcriptExportError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { model.transcriptExportError = nil }
        } message: {
            Text(model.transcriptExportError ?? "")
        }
        .sheet(isPresented: $model.showTranscriptShareSheet, onDismiss: model.cleanupTranscriptExportFile) {
            if let transcriptExportURL = model.transcriptExportURL {
                ActivityShareSheet(items: [transcriptExportURL], onComplete: model.cleanupTranscriptExportFile)
            }
        }
        .task(id: appState.developerMode) {
            await model.refreshGroupManagementAndNotify()
            await model.refreshVisibleDebugState(using: appState)
        }
        .task(id: viewModel.groupMlsRefreshGeneration) {
            await model.refreshVisibleDebugState(using: appState)
        }
        .task(id: viewModel.group.groupIdHex) {
            model.loadMuteState(using: appState)
            await model.loadSharedMedia(using: appState)
            await model.loadSharedGroups(using: appState)
        }
        .refreshable {
            await model.loadSharedMedia(using: appState, force: true)
        }
    }

    // MARK: - Navigation hooks

    /// Details is a sheet over the conversation; search lives in the
    /// conversation chrome, so close the sheet and activate it there.
    private func openConversationSearch() {
        dismiss()
        viewModel.search.activate()
    }

    private func openChat(_ groupIdHex: String) {
        dismiss()
        appState.presentChat(groupIdHex: groupIdHex)
    }

    private var mediaLoader: ConversationMediaLoader {
        ConversationMediaLoader { media in
            try await viewModel.data(for: media)
        }
    }

    private var actionHelpBinding: Binding<Bool> {
        Binding(
            get: { model.actionHelp != nil },
            set: { if !$0 { model.actionHelp = nil } }
        )
    }

    // MARK: - Confirmations

    @ViewBuilder
    private func fullScreenConfirmation(for confirmation: GroupDetailsConfirmation) -> some View {
        switch confirmation {
        case .leave:
            FullScreenConfirmationDialog(
                title: isDirectMessage ? L10n.string("Leave this chat?") : L10n.string("Leave this group?"),
                message: GroupManagementPresentation.leaveConfirmationMessage(state: viewModel.managementState),
                systemImage: "rectangle.portrait.and.arrow.right",
                destructiveTitle: "Leave",
                onConfirm: {
                    model.pendingConfirmation = nil
                    Task { await model.leave(using: appState, dismiss: { dismiss() }) }
                },
                onCancel: { model.pendingConfirmation = nil }
            )
        case .deleteLocal:
            FullScreenConfirmationDialog(
                title: "Delete local copy?",
                message: "This removes the local history from this device. It won't send a leave proposal.",
                systemImage: "trash",
                destructiveTitle: "Delete Local Copy",
                onConfirm: {
                    model.pendingConfirmation = nil
                    Task { await model.deleteLocal(using: appState, dismiss: { dismiss() }) }
                },
                onCancel: { model.pendingConfirmation = nil }
            )
        case .remove(let member):
            FullScreenConfirmationDialog(
                title: "Remove this member?",
                message: "They'll stop receiving new messages in this group.",
                systemImage: "person.crop.circle.badge.minus",
                destructiveTitle: "Remove from Group",
                onConfirm: {
                    model.pendingConfirmation = nil
                    Task { await model.remove(member: member, using: appState) }
                },
                onCancel: { model.pendingConfirmation = nil }
            )
        case .selfDemote:
            FullScreenConfirmationDialog(
                title: "Step down as admin?",
                message: "You'll stay in the group, but another admin will need to restore your admin status.",
                systemImage: "star.slash",
                destructiveTitle: "Step Down",
                onConfirm: {
                    model.pendingConfirmation = nil
                    Task { await model.selfDemote(using: appState) }
                },
                onCancel: { model.pendingConfirmation = nil }
            )
        }
    }

    // MARK: - Group sections

    private var editMenu: some View {
        Menu {
            Button {
                model.renameDraft = ContentSanitizer.groupName(viewModel.group.name) ?? ""
                model.showRename = true
            } label: {
                Label(viewModel.group.name.isEmpty ? "Set Name" : "Edit Name", systemImage: "pencil")
            }
            Button {
                model.descriptionDraft = ContentSanitizer.multilineText(
                    viewModel.group.description,
                    maxLength: ContentSanitizer.maxGroupDescriptionLength
                ) ?? ""
                model.showDescriptionEditor = true
            } label: {
                Label(
                    Self.normalizedGroupDescriptionForUpdate(viewModel.group.description).isEmpty
                        ? "Set Description"
                        : "Edit Description",
                    systemImage: "text.alignleft"
                )
            }
            Button {
                model.showGroupImageEditor = true
            } label: {
                Label(
                    viewModel.group.avatarUrl == nil ? "Set Image" : "Edit Image",
                    systemImage: "photo"
                )
            }
        } label: {
            Text("Edit")
        }
        .disabled(model.membershipActionInFlight)
        .accessibilityLabel("Edit group")
    }

    private var identityHeaderSection: some View {
        let groupDisplay = viewModel.groupDisplay
        let displayTitle = viewModel.displayTitle(for: groupDisplay)
        return Section {
            VStack(spacing: 10) {
                Group {
                    if isAdmin {
                        Button {
                            model.showGroupImageEditor = true
                        } label: {
                            groupAvatar(groupDisplay: groupDisplay, displayTitle: displayTitle)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(
                            viewModel.group.avatarUrl == nil
                                ? L10n.string("Set group image")
                                : L10n.string("Edit group image")
                        )
                    } else {
                        groupAvatar(groupDisplay: groupDisplay, displayTitle: displayTitle)
                    }
                }

                Text(displayTitle)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(L10n.plural("Group · %lld members", Int64(memberCount)))
                    .font(.callout)
                    .foregroundStyle(.secondary)

                if let description = ContentSanitizer.multilineText(
                    viewModel.group.description,
                    maxLength: ContentSanitizer.maxGroupDescriptionLength
                ) {
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                } else if isAdmin {
                    Button {
                        model.descriptionDraft = ""
                        model.showDescriptionEditor = true
                    } label: {
                        Text("Add Description")
                            .font(.callout)
                    }
                    .disabled(model.membershipActionInFlight)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
        }
    }

    private func groupAvatar(groupDisplay: GroupDisplay.Resolved, displayTitle: String) -> some View {
        AvatarBubble(
            seed: GroupDisplay.avatarSeed(for: groupDisplay),
            title: displayTitle,
            pictureURL: GroupDisplay.avatarURL(for: groupDisplay, appState: appState)
        )
        .frame(width: 88, height: 88)
    }

    private var groupActionsRowSection: some View {
        Section {
            HStack(spacing: 10) {
                if GroupManagementPresentation.canInvite(
                    state: viewModel.managementState,
                    fallbackIsAdmin: isAdmin
                ) {
                    DetailsActionButton(
                        title: "Add",
                        systemImage: "person.crop.circle.badge.plus",
                        isDisabled: model.membershipActionInFlight,
                        action: { model.showAddMembers = true }
                    )
                }
                DetailsActionButton(
                    title: model.isMuted ? "Unmute" : "Mute",
                    systemImage: model.isMuted ? "bell.fill" : "bell.slash",
                    action: { model.setMuted(!model.isMuted, using: appState) }
                )
                DetailsActionButton(
                    title: "Search",
                    systemImage: "magnifyingglass",
                    action: openConversationSearch
                )
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    private var sharedMediaSection: some View {
        GroupSharedMediaSection(
            records: model.sharedMediaRecords,
            isLoading: model.isLoadingSharedMedia,
            error: model.sharedMediaError,
            onRetry: {
                Task { await model.loadSharedMedia(using: appState, force: true) }
            },
            onLoadMedia: mediaLoader,
            onOpenGallery: { gallery in
                sharedMediaGallery = gallery
            }
        )
    }

    private var groupSettingsSection: some View {
        Section {
            if isAdmin {
                Button {
                    model.showRetentionEditor = true
                } label: {
                    LabeledContent("Disappearing messages") {
                        HStack(spacing: 6) {
                            Text(GroupSystemEventPresentation.retentionSettingLabel(
                                seconds: viewModel.group.disappearingMessageSecs
                            ))
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(model.membershipActionInFlight)
            } else {
                LabeledContent(
                    "Disappearing messages",
                    value: GroupSystemEventPresentation.retentionSettingLabel(
                        seconds: viewModel.group.disappearingMessageSecs
                    )
                )
            }

            Button {
                Task { await model.setArchived(!viewModel.group.archived, using: appState) }
            } label: {
                Label(
                    viewModel.group.archived ? L10n.string("Unarchive Group") : L10n.string("Archive Group"),
                    systemImage: viewModel.group.archived ? "tray.and.arrow.up" : "archivebox"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(model.membershipActionInFlight)
        } header: {
            Text("Settings")
        } footer: {
            Text("Archiving hides the group from your main chats list. It doesn't change your membership or notify anyone.")
        }
    }

    private var membersSection: some View {
        let details = viewModel.groupMemberDetails
        let namesByMemberId = memberNamesById(details)
        let ordered = GroupMemberOrdering.ordered(details, namesByMemberId: namesByMemberId)
        let filtered = GroupMemberOrdering.filtered(
            ordered,
            query: memberSearchText,
            namesByMemberId: namesByMemberId
        )
        let isSearching = !memberSearchText.trimmingCharacters(in: .whitespaces).isEmpty
        let visible = GroupMemberOrdering.visible(
            filtered,
            isSearching: isSearching,
            isExpanded: membersExpanded
        )
        return Section {
            if details.count > GroupMemberOrdering.previewCount {
                memberSearchField
            }

            if details.isEmpty {
                ForEach(viewModel.members, id: \.memberIdHex) { member in
                    GroupMemberRow(member: member, isAdmin: viewModel.isAdmin(member))
                }
            } else if filtered.isEmpty {
                Text("No members match your search.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(visible, id: \.memberIdHex) { member in
                    HStack(spacing: 8) {
                        Button {
                            memberProfileNpub = member.npub
                        } label: {
                            GroupMemberDetailsRow(member: member)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        memberActionsMenu(for: member)
                    }
                    .swipeActions(edge: .trailing) {
                        swipeActions(for: member)
                    }
                }
                if !isSearching, !membersExpanded, filtered.count > GroupMemberOrdering.previewCount {
                    Button {
                        membersExpanded = true
                    } label: {
                        Text(L10n.plural("See all %lld members", Int64(filtered.count)))
                    }
                }
            }
        } header: {
            Text(L10n.plural("%lld members", Int64(memberCount)))
        } footer: {
            if !GroupManagementPresentation.canInvite(
                state: viewModel.managementState,
                fallbackIsAdmin: isAdmin
            ) {
                Text("Only admins can add or manage members.")
            }
        }
    }

    private var memberSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search members", text: $memberSearchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !memberSearchText.isEmpty {
                Button {
                    memberSearchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear member search")
            }
        }
    }

    private func memberNamesById(_ details: [GroupMemberDetailsFfi]) -> [String: String] {
        var names: [String: String] = [:]
        names.reserveCapacity(details.count)
        for member in details {
            names[member.memberIdHex] = GroupMemberDetailsPresentation.displayName(
                for: member,
                appState: appState
            )
        }
        return names
    }

    private var technicalDetailsSection: some View {
        Section {
            DisclosureGroup(isExpanded: $showTechnicalDetails) {
                copyableDeveloperValueRow(title: "Group ID", value: viewModel.group.groupIdHex)
                LabeledContent("Relays") {
                    Text(GroupRelaysPresentation.countLabel(for: viewModel.group.relays))
                        .foregroundStyle(.secondary)
                }
                // Stable per-row identity by position. Sanitized display strings can
                // collide (distinct raw relays sanitize to the same line), so id: \.self
                // would produce duplicate SwiftUI identities on hostile relay input.
                ForEach(Array(GroupRelaysPresentation.rows(for: viewModel.group.relays).enumerated()), id: \.offset) { _, relay in
                    Text(relay)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(relay == GroupRelaysPresentation.emptyMessage ? .secondary : .primary)
                        .textSelection(.enabled)
                }
            } label: {
                Text("Technical Details")
            }
        }
    }

    private var destructiveActionsSection: some View {
        Section {
            if shouldShowSelfDemoteAction {
                groupActionRow(
                    title: L10n.string("Step Down as Admin"),
                    systemImage: "star.slash",
                    role: .destructive,
                    isDisabled: !canSelfDemoteAction || model.membershipActionInFlight,
                    help: .stepDown
                ) {
                    model.pendingConfirmation = .selfDemote
                }
            }

            if viewModel.canSendMessages {
                groupActionRow(
                    title: L10n.string("Leave Group"),
                    systemImage: "rectangle.portrait.and.arrow.right",
                    role: .destructive,
                    isDisabled: !GroupManagementPresentation.canLeave(
                        state: viewModel.managementState,
                        fallbackIsLastAdmin: viewModel.isLastAdmin
                    )
                        || model.membershipActionInFlight,
                    help: .leave(message: GroupManagementPresentation.leaveHelpMessage(
                        state: viewModel.managementState,
                        fallbackIsLastAdmin: viewModel.isLastAdmin
                    ))
                ) {
                    model.pendingConfirmation = .leave
                }
            } else {
                groupActionRow(
                    title: "Delete Local Copy",
                    systemImage: "trash",
                    role: .destructive,
                    isDisabled: model.membershipActionInFlight,
                    help: .deleteLocal
                ) {
                    model.pendingConfirmation = .deleteLocal
                }
            }
        }
    }

    private var transcriptExportSection: some View {
        Section {
            Button {
                Task { await model.exportConversationTranscript(using: appState) }
            } label: {
                HStack {
                    Label("Export Conversation Transcript", systemImage: "doc.text")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if model.isExportingTranscript {
                        ProgressView()
                    }
                }
            }
            .disabled(model.isExportingTranscript || appState.activeAccountRef == nil)
        } footer: {
            Text("Exports the raw inner Nostr event history for this group as JSON (kinds 9, 1200–1210, and related metadata), ordered by time. Use Share to copy or save the file.")
        }
    }

    private var shouldShowSelfDemoteAction: Bool {
        isAdmin || viewModel.managementState?.requiresSelfDemoteBeforeLeave == true
    }

    private var canSelfDemoteAction: Bool {
        if GroupManagementPresentation.canSelfDemote(state: viewModel.managementState) { return true }
        return viewModel.managementState == nil && isAdmin && !viewModel.isLastAdmin
    }

    private func groupActionRow(
        title: String,
        systemImage: String,
        role: ButtonRole? = nil,
        isDisabled: Bool,
        help: GroupActionHelp,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Button(role: role, action: action) {
                groupActionLabel(title, systemImage: systemImage)
            }
            .disabled(isDisabled)

            Button {
                model.actionHelp = help
            } label: {
                Image(systemName: "info.circle")
                    .imageScale(.large)
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel(L10n.formatted("%@ info", title))
        }
    }

    private func groupActionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }

    private var developerSection: some View {
        Section {
            copyableDeveloperValueRow(
                title: "MLS group ID",
                value: model.mlsState?.groupIdHex ?? viewModel.group.groupIdHex
            )
            copyableDeveloperValueRow(title: "Nostr group ID", value: viewModel.group.nostrGroupIdHex)
            if let mlsState = model.mlsState {
                LabeledContent("Epoch", value: "\(mlsState.epoch)")
                LabeledContent("Members (MLS)", value: "\(mlsState.memberCount)")
                LabeledContent("Required components") {
                    Text(mlsState.requiredAppComponents.map(String.init).joined(separator: ", "))
                        .font(.caption.monospaced())
                }
            } else {
                Text("Loading MLS state…")
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Admins", value: "\(viewModel.group.admins.count)")
        } header: {
            Text("MLS group (developer)")
        }
    }

    private var pushNotificationsDeveloperSection: some View {
        Section("Push notifications (developer)") {
            if let pushDebugInfo = model.pushDebugInfo {
                LabeledContent("Tokens") {
                    Text(GroupPushDebugPresentation.tokenSummary(for: pushDebugInfo))
                        .monospacedDigit()
                }
                LabeledContent("Relay hints") {
                    Text(GroupPushDebugPresentation.missingRelayHintSummary(for: pushDebugInfo))
                        .monospacedDigit()
                }
                LabeledContent("Local registration") {
                    Text(GroupPushDebugPresentation.localRegistrationSummary(for: pushDebugInfo.localRegistration))
                        .foregroundStyle(.secondary)
                }
                if let leafIndex = pushDebugInfo.localRegistration.localLeafIndex {
                    LabeledContent("Local leaf", value: "\(leafIndex)")
                }
                if let updatedAtMs = pushDebugInfo.lastTokenListUpdatedAtMs {
                    LabeledContent("Last token list update") {
                        Text(Date(timeIntervalSince1970: TimeInterval(updatedAtMs) / 1000), style: .relative)
                    }
                }
                if !pushDebugInfo.tokens.isEmpty {
                    DisclosureGroup("Token fingerprints") {
                        ForEach(Array(pushDebugInfo.tokens.enumerated()), id: \.offset) { _, token in
                            tokenDebugRow(token)
                        }
                    }
                }
            } else if let pushDebugError = model.pushDebugError {
                Label(pushDebugError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else {
                Text("Loading push notification state…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func copyableDeveloperValueRow(title: String, value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            Haptics.selection()
            appState.present(.success(L10n.string("Copied to clipboard"), message: title))
        } label: {
            LabeledContent(title) {
                HStack(spacing: 6) {
                    Text(value)
                        .font(.system(.caption2, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(L10n.formatted("Copies %@", title))
    }

    private func tokenDebugRow(_ token: GroupPushTokenDebugEntryFfi) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(GroupPushDebugPresentation.platformLabel(token.platform))
                    .font(.caption.weight(.semibold))
                Text("leaf \(token.leafIndex)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if token.isLocalMember {
                    Text("local")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.16), in: Capsule())
                        .foregroundStyle(.tint)
                }
                if !token.activeLeaf {
                    Text("stale")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.16), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
            Text(token.tokenFingerprint)
                .font(.system(.caption2, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Text(IdentityFormatter.short(token.memberIdHex, head: 12, tail: 12))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Member actions

    @ViewBuilder
    private func memberActionsMenu(for member: GroupMemberDetailsFfi) -> some View {
        // Copy npub is available to every member, so the menu always renders.
        // Membership-management actions (admin/remove) stay gated on the
        // caller's permissions and only appear when applicable.
        Menu {
            Button {
                copyNpub(for: member)
            } label: {
                Label("Copy npub", systemImage: "doc.on.doc")
            }

            let actions = memberActions(for: member)
            if !actions.isEmpty {
                Divider()
                memberActionButtons(for: member, actions: actions)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .imageScale(.large)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Member actions")
    }

    @ViewBuilder
    private func memberActionButtons(
        for member: GroupMemberDetailsFfi,
        actions: [GroupMemberManagementAction]
    ) -> some View {
        if actions.contains(.promote) {
            Button {
                Task { await model.setAdmin(member: member, admin: true, using: appState) }
            } label: {
                Label("Make Admin", systemImage: "star")
            }
            .disabled(model.membershipActionInFlight)
        }
        if actions.contains(.demote) {
            Button {
                Task { await model.setAdmin(member: member, admin: false, using: appState) }
            } label: {
                Label("Remove Admin", systemImage: "star.slash")
            }
            .disabled(model.membershipActionInFlight)
        }
        if actions.contains(.selfDemote) {
            Button(role: .destructive) {
                model.pendingConfirmation = .selfDemote
            } label: {
                Label("Step Down as Admin", systemImage: "star.slash")
            }
            .disabled(model.membershipActionInFlight)
        }
        if actions.contains(.remove) {
            Button(role: .destructive) {
                model.pendingConfirmation = .remove(member)
            } label: {
                Label("Remove from Group", systemImage: "person.crop.circle.badge.minus")
            }
            .disabled(model.membershipActionInFlight)
        }
    }

    private func copyNpub(for member: GroupMemberDetailsFfi) {
        UIPasteboard.general.string = member.npub
        Haptics.selection()
        appState.present(.success(L10n.string("Copied to clipboard"), message: L10n.string("npub")))
    }

    @ViewBuilder
    private func swipeActions(for member: GroupMemberDetailsFfi) -> some View {
        let actions = memberActions(for: member)
        if actions.contains(.remove) {
            Button(role: .destructive) {
                model.pendingConfirmation = .remove(member)
            } label: {
                Label("Remove", systemImage: "person.crop.circle.badge.minus")
            }
        }
        if actions.contains(.demote) {
            Button {
                Task { await model.setAdmin(member: member, admin: false, using: appState) }
            } label: {
                Label("Remove Admin", systemImage: "star.slash")
            }
            .tint(.orange)
        }
        if actions.contains(.promote) {
            Button {
                Task { await model.setAdmin(member: member, admin: true, using: appState) }
            } label: {
                Label("Make Admin", systemImage: "star")
            }
            .tint(.orange)
        }
    }

    private func memberActions(for member: GroupMemberDetailsFfi) -> [GroupMemberManagementAction] {
        guard let action = viewModel.managementAction(for: member.memberIdHex) else { return [] }
        return GroupManagementPresentation.memberActions(for: action, state: viewModel.managementState)
    }

    /// A group rename must publish a non-empty sanitized name; an empty value
    /// would silently blank the shared group name (#80), and raw text would
    /// propagate spoofing characters to Marmot/relays (#195).
    static func validatedGroupName(_ draft: String) -> String? {
        ContentSanitizer.groupName(draft)
    }

    /// `nil` means "leave unchanged" to Marmot, while an empty string is the
    /// explicit remove-description sentinel. Keep that distinction at the UI
    /// boundary while still applying the shared peer-text sanitizer.
    static func normalizedGroupDescriptionForUpdate(_ draft: String) -> String {
        ContentSanitizer.multilineText(
            draft,
            maxLength: ContentSanitizer.maxGroupDescriptionLength
        ) ?? ""
    }

}

enum GroupDetailsActionError: Equatable, LocalizedError {
    case noActiveAccount
    case invalidImageURL
    case operationInFlight

    var errorDescription: String? {
        switch self {
        case .noActiveAccount:
            L10n.string("No active account is selected.")
        case .invalidImageURL:
            L10n.string("Use a public HTTPS image URL.")
        case .operationInFlight:
            L10n.string("Another group update is still in progress.")
        }
    }
}

enum GroupActionHelp {
    case stepDown
    case leave(message: String)
    case deleteLocal

    var title: String {
        switch self {
        case .stepDown:
            return L10n.string("Step Down as Admin")
        case .leave:
            return L10n.string("Leave Group")
        case .deleteLocal:
            return "Delete Local Copy"
        }
    }

    var message: String {
        switch self {
        case .stepDown:
            return L10n.string("You'll stay in the group, but another admin will need to restore your admin status.")
        case .leave(let message):
            return message
        case .deleteLocal:
            return "Deletes this group's local history from this device after you have left or been removed."
        }
    }
}
