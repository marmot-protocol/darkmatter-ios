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
    @State private var confirmingRemoval = false
    @State private var showStartGroup = false
    @State private var showAddToGroup = false

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
            aboutSection
            moderationSection
            sharedGroupsSection
        }
        .listStyle(.insetGrouped)
        .task(id: npub) { await model.resolve(npub: npub, using: appState) }
        .task(id: declaredNip05) { await model.verifyDeclaredNip05(declaredNip05) }
        .sheet(isPresented: $showStartGroup) {
            if let hex = model.hex {
                NewChatFlowView(initialGroupMembers: [
                    MemberRefFfi(
                        memberRef: displayReference,
                        accountIdHex: hex,
                        npub: displayReference
                    )
                ])
                .appAppearance()
            }
        }
        .sheet(isPresented: $showAddToGroup) {
            AddToGroupSheet(
                contactNpub: displayReference,
                contactName: title,
                groups: model.addableGroups
            )
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
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private var primaryActionSection: some View {
        if canMessage {
            Section {
                HStack(spacing: 10) {
                    DetailsActionButton(
                        title: "Message",
                        systemImage: "message",
                        isLoading: model.starter.isCreating
                    ) {
                        Task { await model.message(npub: npub, using: appState, onOpen: openChat) }
                    }

                    DetailsActionButton(
                        title: "New Group",
                        systemImage: "person.2.badge.plus"
                    ) {
                        showStartGroup = true
                    }
                    .accessibilityLabel(L10n.formatted("Create group with %@", title))

                    DetailsActionButton(
                        title: "Add to Group",
                        systemImage: "person.badge.plus",
                        isDisabled: model.addableGroups.isEmpty
                    ) {
                        showAddToGroup = true
                    }
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
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

    // MARK: - Groups in common

    @ViewBuilder
    private var sharedGroupsSection: some View {
        if let hex = model.hex, !isSelf {
            GroupsInCommonSection(
                contactAccountIdHex: hex,
                contactNpub: displayReference,
                contactName: title,
                sharedGroups: model.sharedGroups,
                addableGroups: model.addableGroups,
                onOpenChat: openChat,
                showsActions: false,
                onStartGroup: { showStartGroup = true },
                onAddToGroup: { showAddToGroup = true }
            )
        }
    }

    // MARK: - Moderation

    @ViewBuilder
    private var moderationSection: some View {
        if moderation?.actions.isEmpty == false {
            Section {
                moderationButtons
            } header: {
                Text("Group Membership")
            } footer: {
                if moderation?.isAdmin == true {
                    Text("This person is a group admin.")
                }
            }
        }
    }

    @ViewBuilder
    private var moderationButtons: some View {
        if let moderation, !moderation.actions.isEmpty {
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
        }
    }

    // MARK: - Helpers

    private func openChat(_ groupIdHex: String) {
        DeferredChatPresentation.present(
            groupIdHex: groupIdHex,
            using: appState,
            dismissFirst: dismiss
        )
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

    private var canMessage: Bool {
        model.hex != nil && !isSelf && appState.activeAccountRef != nil
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
