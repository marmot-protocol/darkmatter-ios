import SwiftUI
import MarmotKit

/// Direct-message details: contact identity, supported actions, shared
/// media, notification/privacy settings, shared groups, then local and
/// destructive actions. Rendered inside `GroupDetailsView`'s form so the
/// mutation paths, confirmations, and developer sections stay shared with
/// group details.
struct DirectChatDetailsContent: View {
    @Environment(AppState.self) private var appState
    var viewModel: ConversationViewModel
    @Bindable var model: GroupDetailsViewModel
    let onSearch: () -> Void
    let onOpenChat: (String) -> Void
    let onLoadMedia: ConversationMediaLoader
    let onOpenGallery: (MessageMediaGallery) -> Void

    @State private var editingNickname = false
    @State private var nicknameDraft = ""

    var body: some View {
        identitySection
        actionsSection
        sharedMediaSection
        privacySection
        sharedGroupsSection
        destructiveSection
    }

    // MARK: - Identity

    private var identitySection: some View {
        Section {
            VStack(spacing: 10) {
                AvatarBubble(
                    seed: contactAccountIdHex ?? viewModel.group.groupIdHex,
                    title: contactTitle,
                    pictureURL: contactAccountIdHex.flatMap { appState.avatarURL(forAccountIdHex: $0) }
                )
                .frame(width: 88, height: 88)

                Text(contactTitle)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                // When a private nickname overrides the header, keep the real
                // profile name visible so the override is never confused for
                // the contact's published name.
                if nickname != nil, let profileName {
                    Text(L10n.formatted("Name from profile: %@", profileName))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let nip05 {
                    Text(nip05)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let npub = contactNpub {
                    CopyableIdentityChip(
                        display: IdentityFormatter.short(npub, head: 12, tail: 10),
                        copyValue: npub,
                        copiedToastTitle: L10n.string("npub")
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            // Attached inside the section: presentation modifiers on a Form's
            // Section itself can detach when the form re-renders.
            .alert(nicknameAlertTitle, isPresented: $editingNickname) {
                TextField(L10n.string("Nickname"), text: $nicknameDraft)
                Button(L10n.string("Save"), action: saveNickname)
                Button(L10n.string("Cancel"), role: .cancel) {}
            } message: {
                Text("Only you see this on this device. Clearing it restores their profile name.")
            }
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        Section {
            HStack(spacing: 10) {
                DetailsActionButton(
                    title: model.isMuted ? "Unmute" : "Mute",
                    systemImage: model.isMuted ? "bell.fill" : "bell.slash",
                    action: { model.setMuted(!model.isMuted, using: appState) }
                )
                DetailsActionButton(
                    title: "Search",
                    systemImage: "magnifyingglass",
                    action: onSearch
                )
                DetailsActionButton(
                    title: "Nickname",
                    systemImage: "pencil",
                    isDisabled: !canEditNickname,
                    action: beginEditingNickname
                )
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    // MARK: - Shared media

    private var sharedMediaSection: some View {
        GroupSharedMediaSection(
            records: model.sharedMediaRecords,
            isLoading: model.isLoadingSharedMedia,
            error: model.sharedMediaError,
            onRetry: {
                Task { await model.loadSharedMedia(using: appState, force: true) }
            },
            onLoadMedia: onLoadMedia,
            onOpenGallery: onOpenGallery
        )
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section {
            if viewModel.isSelfAdmin {
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
                    viewModel.group.archived ? L10n.string("Unarchive Chat") : L10n.string("Archive Chat"),
                    systemImage: viewModel.group.archived ? "tray.and.arrow.up" : "archivebox"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(model.membershipActionInFlight)
        } header: {
            Text("Privacy")
        } footer: {
            Text("Archiving hides the chat from your main list. It doesn't notify anyone.")
        }
    }

    // MARK: - Shared groups

    @ViewBuilder
    private var sharedGroupsSection: some View {
        if !model.sharedGroups.isEmpty {
            Section {
                ForEach(model.sharedGroups) { group in
                    Button {
                        onOpenChat(group.groupIdHex)
                    } label: {
                        HStack(spacing: 12) {
                            AvatarBubble(
                                seed: group.groupIdHex,
                                title: group.title,
                                pictureURL: ContentSanitizer.imageURL(group.avatarUrl)
                            )
                            .frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(group.title)
                                    .lineLimit(1)
                                Text(L10n.plural("%lld members", Int64(group.memberCount)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Shared Groups")
            }
        }
    }

    // MARK: - Destructive

    private var destructiveSection: some View {
        Section {
            if viewModel.canSendMessages {
                Button(role: .destructive) {
                    model.pendingConfirmation = .leave
                } label: {
                    Label("Leave Chat", systemImage: "rectangle.portrait.and.arrow.right")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(
                    !GroupManagementPresentation.canLeave(
                        state: viewModel.managementState,
                        fallbackIsLastAdmin: viewModel.isLastAdmin
                    ) || model.membershipActionInFlight
                )
            } else {
                Button(role: .destructive) {
                    model.pendingConfirmation = .deleteLocal
                } label: {
                    Label("Delete Local Copy", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(model.membershipActionInFlight)
            }
        } footer: {
            if viewModel.canSendMessages {
                Text("You'll stop receiving messages from this chat.")
            } else {
                Text("Deletes this chat's local history from this device.")
            }
        }
    }

    // MARK: - Contact identity helpers

    private var contactAccountIdHex: String? { viewModel.otherMember }

    private var contactNpub: String? {
        viewModel.directMessageCounterpartNpub
            ?? contactAccountIdHex.map { appState.npub(forAccountIdHex: $0) }
    }

    private var contactTitle: String {
        guard let contactAccountIdHex else { return viewModel.displayTitle }
        return appState.displayName(forAccountIdHex: contactAccountIdHex)
    }

    private var nickname: String? {
        contactAccountIdHex.flatMap { appState.contactNickname(forAccountIdHex: $0) }
    }

    private var profileName: String? {
        contactAccountIdHex.flatMap { appState.knownProfileDisplayName(forAccountIdHex: $0) }
    }

    private var nip05: String? {
        contactAccountIdHex.flatMap {
            ContentSanitizer.profileAddress(appState.profile(forAccountIdHex: $0)?.nip05)
        }
    }

    private var canEditNickname: Bool {
        contactAccountIdHex != nil && appState.activeAccountRef != nil
    }

    private var nicknameAlertTitle: String {
        nickname == nil ? L10n.string("Set nickname") : L10n.string("Edit nickname")
    }

    private func beginEditingNickname() {
        nicknameDraft = nickname ?? ""
        editingNickname = true
    }

    private func saveNickname() {
        guard let contactAccountIdHex else { return }
        appState.setContactNickname(nicknameDraft, forAccountIdHex: contactAccountIdHex)
        Haptics.selection()
    }
}
