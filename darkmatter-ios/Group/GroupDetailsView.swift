import SwiftUI
import MarmotKit

/// Inspector for a single group. Name, members + admin management,
/// invite/remove, archive, leave, and (in developer mode) MLS internals.
struct GroupDetailsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: ConversationViewModel

    @State private var showAddMembers = false
    @State private var showLeaveConfirm = false
    @State private var showRename = false
    @State private var renameDraft = ""
    @State private var actionError: String?
    @State private var mlsState: AppGroupMlsStateFfi?

    private var isAdmin: Bool { viewModel.isSelfAdmin }

    var body: some View {
        Form {
            headerSection
            infoSection
            membersSection
            archiveSection
            leaveSection

            if appState.developerMode {
                developerSection
            }

            if let actionError {
                Section {
                    Label(actionError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .sheet(isPresented: $showAddMembers) {
            AddMembersSheet(onSubmit: { refs in await invite(refs: refs) })
        }
        .alert("Group name", isPresented: $showRename) {
            TextField("Group name", text: $renameDraft)
            Button("Save") { Task { await rename() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Everyone in the group will see the new name.")
        }
        .confirmationDialog(
            "Leave this group?",
            isPresented: $showLeaveConfirm,
            titleVisibility: .visible
        ) {
            Button("Leave", role: .destructive) {
                Task { await leave() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You'll stop receiving messages from this group. Other members will see a system message.")
        }
        .task(id: appState.developerMode) {
            if appState.developerMode { await loadMlsState() }
        }
    }

    // MARK: - Sections

    private var headerSection: some View {
        Section {
            HStack(spacing: 14) {
                AvatarBubble(
                    seed: GroupDisplay.avatarSeed(group: viewModel.group, otherMember: viewModel.otherMember),
                    title: viewModel.displayTitle,
                    pictureURL: GroupDisplay.avatarURL(group: viewModel.group, otherMember: viewModel.otherMember, appState: appState)
                )
                .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(viewModel.displayTitle)
                        .font(.title3.weight(.semibold))
                    if let description = ProfileSanitizer.multilineText(viewModel.group.description, maxLength: 280) {
                        Text(description)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 6)

            if isAdmin {
                Button {
                    renameDraft = viewModel.group.name
                    showRename = true
                } label: {
                    Label(viewModel.group.name.isEmpty ? "Set group name" : "Edit group name",
                          systemImage: "pencil")
                }
            }
        }
    }

    private var infoSection: some View {
        Section {
            LabeledContent("Group ID") {
                Text(IdentityFormatter.short(viewModel.group.groupIdHex))
                    .font(.system(.caption, design: .monospaced))
            }
            LabeledContent("Members", value: "\(viewModel.members.count)")
            LabeledContent("Relays", value: "\(viewModel.group.relays.count)")
        }
    }

    private var membersSection: some View {
        Section("Members") {
            ForEach(viewModel.members, id: \.memberIdHex) { member in
                GroupMemberRow(member: member, isAdmin: viewModel.isAdmin(member))
                    .swipeActions(edge: .trailing) {
                        if isAdmin && !member.local {
                            Button(role: .destructive) {
                                Task { await remove(member: member) }
                            } label: {
                                Label("Remove", systemImage: "person.crop.circle.badge.minus")
                            }
                            if viewModel.isAdmin(member) {
                                Button {
                                    Task { await setAdmin(member: member, admin: false) }
                                } label: {
                                    Label("Remove Admin", systemImage: "star.slash")
                                }
                                .tint(.orange)
                            } else {
                                Button {
                                    Task { await setAdmin(member: member, admin: true) }
                                } label: {
                                    Label("Make Admin", systemImage: "star")
                                }
                                .tint(.orange)
                            }
                        }
                    }
            }

            Button {
                showAddMembers = true
            } label: {
                Label("Add Members", systemImage: "person.crop.circle.badge.plus")
            }
        }
    }

    private var archiveSection: some View {
        Section {
            Button {
                Task { await setArchived(!viewModel.group.archived) }
            } label: {
                Label(
                    viewModel.group.archived ? "Unarchive Group" : "Archive Group",
                    systemImage: viewModel.group.archived ? "tray.and.arrow.up" : "archivebox"
                )
            }
        } footer: {
            Text("Archiving hides the group from your main chats list. It doesn't change your membership or notify anyone.")
        }
    }

    private var leaveSection: some View {
        Section {
            Button(role: .destructive) {
                showLeaveConfirm = true
            } label: {
                Label("Leave Group", systemImage: "rectangle.portrait.and.arrow.right")
                    .frame(maxWidth: .infinity)
            }
            .disabled(viewModel.isLastAdmin)
        } footer: {
            if viewModel.isLastAdmin {
                Text("You're the only admin. Make another member an admin before you leave.")
            }
        }
    }

    private var developerSection: some View {
        Section("MLS group (developer)") {
            LabeledContent("Group ID") {
                Text(viewModel.group.groupIdHex)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            LabeledContent("Nostr group ID") {
                Text(viewModel.group.nostrGroupIdHex)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let mlsState {
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
        }
    }

    // MARK: - Actions

    private func invite(refs: [String]) async {
        guard let accountRef = appState.activeAccountRef else { return }
        do {
            _ = try await appState.marmot.inviteMembers(
                accountRef: accountRef,
                groupIdHex: viewModel.group.groupIdHex,
                memberRefs: refs
            )
            Haptics.success()
            appState.present(.success("Invited \(refs.count) member\(refs.count == 1 ? "" : "s")"))
        } catch {
            Haptics.error()
            actionError = error.localizedDescription
            appState.present(.error("Invite failed", message: error.localizedDescription))
        }
    }

    private func remove(member: AppGroupMemberRecordFfi) async {
        guard let accountRef = appState.activeAccountRef else { return }
        let target = member.account ?? member.memberIdHex
        do {
            _ = try await appState.marmot.removeMembers(
                accountRef: accountRef,
                groupIdHex: viewModel.group.groupIdHex,
                memberRefs: [target]
            )
            Haptics.success()
            appState.present(.warning("Member removed"))
        } catch {
            Haptics.error()
            actionError = error.localizedDescription
            appState.present(.error("Couldn't remove member", message: error.localizedDescription))
        }
    }

    private func setAdmin(member: AppGroupMemberRecordFfi, admin: Bool) async {
        guard let accountRef = appState.activeAccountRef else { return }
        let target = member.account ?? member.memberIdHex
        do {
            if admin {
                _ = try await appState.marmot.promoteAdmin(
                    accountRef: accountRef,
                    groupIdHex: viewModel.group.groupIdHex,
                    memberRef: target
                )
                appState.present(.success("Made admin"))
            } else {
                _ = try await appState.marmot.demoteAdmin(
                    accountRef: accountRef,
                    groupIdHex: viewModel.group.groupIdHex,
                    memberRef: target
                )
                appState.present(.warning("Admin removed"))
            }
            Haptics.success()
        } catch {
            Haptics.error()
            actionError = error.localizedDescription
            appState.present(.error("Couldn't change admin", message: error.localizedDescription))
        }
    }

    private func rename() async {
        guard let accountRef = appState.activeAccountRef else { return }
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await appState.marmot.updateGroupProfile(
                accountRef: accountRef,
                groupIdHex: viewModel.group.groupIdHex,
                name: name,
                description: nil
            )
            Haptics.success()
            appState.present(.success("Group name updated"))
        } catch {
            Haptics.error()
            actionError = error.localizedDescription
            appState.present(.error("Couldn't rename group", message: error.localizedDescription))
        }
    }

    private func setArchived(_ archived: Bool) async {
        guard let accountRef = appState.activeAccountRef else { return }
        do {
            _ = try appState.marmot.setGroupArchived(
                accountRef: accountRef,
                groupIdHex: viewModel.group.groupIdHex,
                archived: archived
            )
            Haptics.success()
            appState.present(archived ? .warning("Group archived") : .success("Group unarchived"))
        } catch {
            Haptics.error()
            actionError = error.localizedDescription
            appState.present(.error("Couldn't update archive", message: error.localizedDescription))
        }
    }

    private func leave() async {
        guard let accountRef = appState.activeAccountRef else { return }
        do {
            _ = try await appState.marmot.leaveGroup(
                accountRef: accountRef,
                groupIdHex: viewModel.group.groupIdHex
            )
            Haptics.warning()
            appState.present(.warning("You left the group"))
            dismiss()
        } catch {
            Haptics.error()
            actionError = error.localizedDescription
            appState.present(.error("Couldn't leave group", message: error.localizedDescription))
        }
    }

    private func loadMlsState() async {
        guard let accountRef = appState.activeAccountRef else { return }
        mlsState = try? await appState.marmot.groupMlsState(
            accountRef: accountRef,
            groupIdHex: viewModel.group.groupIdHex
        )
    }
}
