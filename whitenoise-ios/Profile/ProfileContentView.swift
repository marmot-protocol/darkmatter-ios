import SwiftUI
import MarmotKit

/// Moderation scope handed to the profile surface when it's opened from a
/// group's member list. Actions come from the live management state; the
/// mutations run through the details view model so permission enforcement
/// stays in the mutation path.
struct ProfileModerationContext {
    let actions: [GroupMemberManagementAction]
    let isAdmin: Bool
    let isBusy: Bool
    let onPromote: () -> Void
    let onDemote: () -> Void
    let onRemove: () -> Void
}

/// Reusable profile content: identity, copyable npub, Message, private
/// nickname, About, shared groups, group actions, and contextual moderation.
/// Presented as a sheet in conversational contexts and pushed or sheeted as
/// a destination for deep links and QR scans.
struct ProfileContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let npub: String
    var moderation: ProfileModerationContext?

    @State private var model = ProfileViewModel()
    @State private var editingNickname = false
    @State private var nicknameDraft = ""
    @State private var startGroupSeed: StartGroupSeed?
    @State private var confirmingRemoval = false

    private struct StartGroupSeed: Identifiable {
        let members: [MemberRefFfi]
        let id = UUID()
    }

    var body: some View {
        List {
            headerSection

            if let prompt = model.startPrompt {
                StartChatPromptSection(
                    prompt: prompt,
                    onRetry: {
                        Task { await model.retryStart(using: appState, onOpen: openChat) }
                    },
                    onDismiss: { model.startPrompt = nil }
                )
            }

            primaryActionSection
            nicknameSection
            aboutSection
            sharedGroupsSection
            groupActionsSection
            moderationSection
        }
        .listStyle(.insetGrouped)
        .task(id: npub) { await model.resolve(npub: npub, using: appState) }
        .task(id: declaredNip05) { await model.verifyDeclaredNip05(declaredNip05) }
        .sheet(item: $startGroupSeed) { seed in
            NewChatFlowView(initialGroupMembers: seed.members)
                .appAppearance()
        }
    }

    // MARK: - Identity

    private var headerSection: some View {
        Section {
            VStack(spacing: 10) {
                AvatarBubble(
                    seed: model.hex ?? npub,
                    title: title,
                    pictureURL: model.hex.flatMap { appState.avatarURL(forAccountIdHex: $0) }
                )
                .frame(width: 96, height: 96)

                Text(title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                // When a private nickname overrides the header, keep the real
                // profile name visible as secondary text so the override is
                // never silently confused for the contact's published name.
                if nickname != nil, let profileName {
                    Text(L10n.formatted("Name from profile: %@", profileName))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                if let nip05 = declaredNip05 {
                    HStack(spacing: 5) {
                        Text(nip05)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if model.verifiedNip05 == nip05 {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.caption)
                                .foregroundStyle(.tint)
                                .accessibilityLabel("Verified address")
                        }
                    }
                }

                CopyableIdentityChip(
                    display: IdentityFormatter.short(displayReference, head: 12, tail: 10),
                    copyValue: displayReference,
                    copiedToastTitle: L10n.string("npub")
                )

                if model.hex == nil {
                    Label("Couldn't read this profile code.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .listRowBackground(Color.clear)
            // Attached inside the section: presentation modifiers on a Form's
            // Section itself can detach when the list re-renders.
            .alert(nicknameAlertTitle, isPresented: $editingNickname) {
                TextField(L10n.string("Nickname"), text: $nicknameDraft)
                Button(L10n.string("Save"), action: saveNickname)
                Button(L10n.string("Cancel"), role: .cancel) {}
            } message: {
                Text("Only you see this on this device. Clearing it restores their profile name.")
            }
        }
    }

    // MARK: - Message

    @ViewBuilder
    private var primaryActionSection: some View {
        if canMessage {
            Section {
                Button {
                    Task { await model.message(npub: npub, using: appState, onOpen: openChat) }
                } label: {
                    HStack {
                        if model.starter.isCreating {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Label("Message", systemImage: "bubble.left.and.bubble.right.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .disabled(model.starter.isCreating)
            }
        }
    }

    // MARK: - Nickname

    @ViewBuilder
    private var nicknameSection: some View {
        if canEditNickname {
            Section {
                Button(action: beginEditingNickname) {
                    LabeledContent(nickname == nil ? "Set nickname" : "Edit nickname") {
                        HStack(spacing: 6) {
                            if let nickname {
                                Text(nickname)
                                    .lineLimit(1)
                            }
                            Image(systemName: "pencil")
                                .font(.caption)
                                .foregroundStyle(.tint)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            } footer: {
                Text("Only you see this on this device. Clearing it restores their profile name.")
            }
        }
    }

    // MARK: - About

    @ViewBuilder
    private var aboutSection: some View {
        if let about {
            Section("About") {
                Text(about)
                    .font(.callout)
            }
        }
    }

    // MARK: - Shared groups

    @ViewBuilder
    private var sharedGroupsSection: some View {
        if !model.sharedGroups.isEmpty {
            Section("Shared Groups") {
                ForEach(model.sharedGroups) { group in
                    Button {
                        openChat(group.groupIdHex)
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
            }
        }
    }

    // MARK: - Group actions

    @ViewBuilder
    private var groupActionsSection: some View {
        if canMessage {
            Section {
                Button {
                    guard let hex = model.hex else { return }
                    startGroupSeed = StartGroupSeed(members: [
                        MemberRefFfi(
                            memberRef: appState.npub(forAccountIdHex: hex),
                            accountIdHex: hex,
                            npub: appState.npub(forAccountIdHex: hex)
                        )
                    ])
                } label: {
                    Label("Start a Group", systemImage: "person.2")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            } footer: {
                Text(L10n.formatted("Creates a new group that includes %@.", title))
            }
        }
    }

    // MARK: - Moderation

    @ViewBuilder
    private var moderationSection: some View {
        if let moderation, !moderation.actions.isEmpty {
            Section {
                if moderation.actions.contains(.promote) {
                    Button {
                        moderation.onPromote()
                        dismiss()
                    } label: {
                        Label("Make Admin", systemImage: "star")
                    }
                    .disabled(moderation.isBusy)
                }
                if moderation.actions.contains(.demote) {
                    Button {
                        moderation.onDemote()
                        dismiss()
                    } label: {
                        Label("Remove Admin", systemImage: "star.slash")
                    }
                    .disabled(moderation.isBusy)
                }
                if moderation.actions.contains(.remove) {
                    Button(role: .destructive) {
                        confirmingRemoval = true
                    } label: {
                        Label("Remove from Group", systemImage: "person.crop.circle.badge.minus")
                    }
                    .disabled(moderation.isBusy)
                    .confirmationDialog(
                        "Remove this member?",
                        isPresented: $confirmingRemoval,
                        titleVisibility: .visible
                    ) {
                        Button("Remove from Group", role: .destructive) {
                            moderation.onRemove()
                            dismiss()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("They'll stop receiving new messages in this group.")
                    }
                }
            } header: {
                Text("Group Membership")
            } footer: {
                if moderation.isAdmin {
                    Text("This person is a group admin.")
                }
            }
        }
    }

    // MARK: - Helpers

    private func openChat(_ groupIdHex: String) {
        dismiss()
        appState.presentChat(groupIdHex: groupIdHex)
    }

    private var title: String {
        if let hex = model.hex { return appState.displayName(forAccountIdHex: hex) }
        return IdentityFormatter.short(npub)
    }

    private var nickname: String? {
        model.hex.flatMap { appState.contactNickname(forAccountIdHex: $0) }
    }

    private var profileName: String? {
        model.hex.flatMap { appState.knownProfileDisplayName(forAccountIdHex: $0) }
    }

    private var declaredNip05: String? {
        model.hex.flatMap {
            ContentSanitizer.profileAddress(appState.profile(forAccountIdHex: $0)?.nip05)
        }
    }

    private var about: String? {
        model.hex.flatMap {
            ContentSanitizer.multilineText(
                appState.profile(forAccountIdHex: $0)?.about,
                maxLength: ContentSanitizer.maxAboutLength
            )
        }
    }

    /// Nicknames apply to other people, not this device's own accounts, and
    /// only once the profile reference resolves to an account id. Requires an
    /// active account too, since the nickname is scoped to (owner, contact).
    private var canEditNickname: Bool {
        model.hex != nil && !isSelf && appState.activeAccountRef != nil
    }

    private var canMessage: Bool {
        model.hex != nil && !isSelf && appState.activeAccountRef != nil
    }

    private var nicknameAlertTitle: String {
        nickname == nil ? L10n.string("Set nickname") : L10n.string("Edit nickname")
    }

    private func beginEditingNickname() {
        nicknameDraft = nickname ?? ""
        editingNickname = true
    }

    private func saveNickname() {
        guard let hex = model.hex else { return }
        // An empty/whitespace draft clears the nickname (store-side sanitize).
        appState.setContactNickname(nicknameDraft, forAccountIdHex: hex)
        Haptics.selection()
    }

    private var displayReference: String {
        if let hex = model.hex { return appState.npub(forAccountIdHex: hex) }
        return npub
    }

    private var isSelf: Bool {
        guard let hex = model.hex else { return false }
        return appState.accounts.contains { $0.accountIdHex == hex }
    }
}

/// Sheet wrapper for conversational contexts (member lists, headers).
struct ProfileSheetView: View {
    @Environment(\.dismiss) private var dismiss
    let npub: String
    var moderation: ProfileModerationContext?

    var body: some View {
        NavigationStack {
            ProfileContentView(npub: npub, moderation: moderation)
                .navigationTitle("Profile")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
