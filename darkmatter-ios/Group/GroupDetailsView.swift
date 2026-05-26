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
    @State private var pendingRemoval: GroupMemberDetailsFfi?
    @State private var showSelfDemoteConfirm = false
    @State private var membershipActionInFlight = false
    @State private var showRelays = false
    @State private var actionHelp: GroupActionHelp?

    private var isAdmin: Bool { viewModel.isSelfAdmin }
    private var memberCount: Int {
        viewModel.groupMemberDetails.isEmpty ? viewModel.members.count : viewModel.groupMemberDetails.count
    }
    private var mlsRefreshKey: String {
        [
            viewModel.group.groupIdHex,
            viewModel.group.admins.joined(separator: ","),
            viewModel.members.map(\.memberIdHex).joined(separator: ","),
            viewModel.groupMemberDetails.map { "\($0.memberIdHex):\($0.isAdmin)" }.joined(separator: ",")
        ].joined(separator: "|")
    }

    var body: some View {
        Form {
            headerSection
            membersSection
            infoSection
            groupActionsSection

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
            AddMembersSheet(
                normalize: { try appState.marmot.normalizeMemberRef(memberRef: $0) },
                onSubmit: { refs in try await invite(refs: refs) }
            )
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
            Text(GroupManagementPresentation.leaveConfirmationMessage(state: viewModel.managementState))
        }
        .confirmationDialog(
            "Remove this member?",
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove from Group", role: .destructive) {
                guard let pendingRemoval else { return }
                Task { await remove(member: pendingRemoval) }
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("They'll stop receiving new messages in this group.")
        }
        .confirmationDialog(
            "Step down as admin?",
            isPresented: $showSelfDemoteConfirm,
            titleVisibility: .visible
        ) {
            Button("Step Down", role: .destructive) {
                Task { await selfDemote() }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("You'll stay in the group, but another admin will need to restore your admin status.")
        }
        .alert(actionHelp?.title ?? "", isPresented: actionHelpBinding) {
            Button("OK", role: .cancel) { actionHelp = nil }
        } message: {
            Text(actionHelp?.message ?? "")
        }
        .task(id: appState.developerMode) {
            await viewModel.refreshGroupManagement()
            await refreshVisibleMlsState()
        }
        .task(id: mlsRefreshKey) {
            await refreshVisibleMlsState()
        }
    }

    // MARK: - Sections

    private var actionHelpBinding: Binding<Bool> {
        Binding(
            get: { actionHelp != nil },
            set: { if !$0 { actionHelp = nil } }
        )
    }

    private var headerSection: some View {
        Section {
            HStack(spacing: 14) {
                AvatarBubble(
                    seed: GroupDisplay.avatarSeed(group: viewModel.group, otherMember: viewModel.otherMember, memberCount: memberCount),
                    title: viewModel.displayTitle,
                    pictureURL: GroupDisplay.avatarURL(group: viewModel.group, otherMember: viewModel.otherMember, memberCount: memberCount, appState: appState)
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
            LabeledContent("Members", value: "\(memberCount)")
            DisclosureGroup(isExpanded: $showRelays) {
                ForEach(GroupRelaysPresentation.rows(for: viewModel.group.relays), id: \.self) { relay in
                    Text(relay)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(relay == GroupRelaysPresentation.emptyMessage ? .secondary : .primary)
                        .textSelection(.enabled)
                }
            } label: {
                HStack {
                    Text("Relays")
                    Spacer()
                    Text(GroupRelaysPresentation.countLabel(for: viewModel.group.relays))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var membersSection: some View {
        Section {
            if viewModel.groupMemberDetails.isEmpty {
                ForEach(viewModel.members, id: \.memberIdHex) { member in
                    GroupMemberRow(member: member, isAdmin: viewModel.isAdmin(member))
                }
            } else {
                ForEach(viewModel.groupMemberDetails, id: \.memberIdHex) { member in
                    HStack(spacing: 8) {
                        GroupMemberDetailsRow(member: member)
                        memberActionsMenu(for: member)
                    }
                    .swipeActions(edge: .trailing) {
                        swipeActions(for: member)
                    }
                }
            }

            if GroupManagementPresentation.canInvite(
                state: viewModel.managementState,
                fallbackIsAdmin: isAdmin
            ) {
                Button {
                    showAddMembers = true
                } label: {
                    Label("Add Members", systemImage: "person.crop.circle.badge.plus")
                }
                .disabled(membershipActionInFlight)
            }
        } footer: {
            if !GroupManagementPresentation.canInvite(
                state: viewModel.managementState,
                fallbackIsAdmin: isAdmin
            ) {
                Text("Only admins can add or manage members.")
            }
        }
    }

    private var groupActionsSection: some View {
        Section {
            groupActionRow(
                title: viewModel.group.archived ? "Unarchive Group" : "Archive Group",
                systemImage: viewModel.group.archived ? "tray.and.arrow.up" : "archivebox",
                isDisabled: membershipActionInFlight,
                help: .archive
            ) {
                Task { await setArchived(!viewModel.group.archived) }
            }

            if shouldShowSelfDemoteAction {
                groupActionRow(
                    title: "Step Down as Admin",
                    systemImage: "star.slash",
                    role: .destructive,
                    isDisabled: !canSelfDemoteAction || membershipActionInFlight,
                    help: .stepDown
                ) {
                    showSelfDemoteConfirm = true
                }
            }

            groupActionRow(
                title: "Leave Group",
                systemImage: "rectangle.portrait.and.arrow.right",
                role: .destructive,
                isDisabled: !GroupManagementPresentation.canLeave(
                    state: viewModel.managementState,
                    fallbackIsLastAdmin: viewModel.isLastAdmin
                )
                    || membershipActionInFlight,
                help: .leave(message: GroupManagementPresentation.leaveHelpMessage(
                    state: viewModel.managementState,
                    fallbackIsLastAdmin: viewModel.isLastAdmin
                ))
            ) {
                showLeaveConfirm = true
            }
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
                actionHelp = help
            } label: {
                Image(systemName: "info.circle")
                    .imageScale(.large)
                    .frame(width: 32, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("\(title) info")
        }
    }

    private func groupActionLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
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

    @ViewBuilder
    private func memberActionsMenu(for member: GroupMemberDetailsFfi) -> some View {
        let actions = memberActions(for: member)
        if !actions.isEmpty {
            Menu {
                memberActionButtons(for: member, actions: actions)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .imageScale(.large)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(membershipActionInFlight)
            .accessibilityLabel("Member actions")
        }
    }

    @ViewBuilder
    private func memberActionButtons(
        for member: GroupMemberDetailsFfi,
        actions: [GroupMemberManagementAction]
    ) -> some View {
        if actions.contains(.promote) {
            Button {
                Task { await setAdmin(member: member, admin: true) }
            } label: {
                Label("Make Admin", systemImage: "star")
            }
        }
        if actions.contains(.demote) {
            Button {
                Task { await setAdmin(member: member, admin: false) }
            } label: {
                Label("Remove Admin", systemImage: "star.slash")
            }
        }
        if actions.contains(.selfDemote) {
            Button(role: .destructive) {
                showSelfDemoteConfirm = true
            } label: {
                Label("Step Down as Admin", systemImage: "star.slash")
            }
        }
        if actions.contains(.remove) {
            Button(role: .destructive) {
                pendingRemoval = member
            } label: {
                Label("Remove from Group", systemImage: "person.crop.circle.badge.minus")
            }
        }
    }

    @ViewBuilder
    private func swipeActions(for member: GroupMemberDetailsFfi) -> some View {
        let actions = memberActions(for: member)
        if actions.contains(.remove) {
            Button(role: .destructive) {
                pendingRemoval = member
            } label: {
                Label("Remove", systemImage: "person.crop.circle.badge.minus")
            }
        }
        if actions.contains(.demote) {
            Button {
                Task { await setAdmin(member: member, admin: false) }
            } label: {
                Label("Remove Admin", systemImage: "star.slash")
            }
            .tint(.orange)
        }
        if actions.contains(.promote) {
            Button {
                Task { await setAdmin(member: member, admin: true) }
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

    private func invite(refs: [String]) async throws {
        guard let accountRef = appState.activeAccountRef else { throw GroupDetailsActionError.noActiveAccount }
        membershipActionInFlight = true
        defer { membershipActionInFlight = false }
        do {
            appState.present(.warning("Inviting members…", message: "Publishing group update."))
            let result = try await appState.marmot.inviteMembersDetailed(
                accountRef: accountRef,
                groupIdHex: viewModel.group.groupIdHex,
                memberRefs: refs
            )
            viewModel.applyGroupMutation(result)
            await refreshVisibleMlsState()
            Haptics.success()
            appState.present(.success(
                "Invited \(refs.count) member\(refs.count == 1 ? "" : "s")",
                message: publishMessage(for: result.summary)
            ))
        } catch {
            await refreshAfterFailedMutation()
            handleActionError(error, title: "Invite failed")
            throw error
        }
    }

    private func remove(member: GroupMemberDetailsFfi) async {
        pendingRemoval = nil
        guard let accountRef = appState.activeAccountRef else { return }
        membershipActionInFlight = true
        defer { membershipActionInFlight = false }
        do {
            appState.present(.warning("Removing member…", message: "Publishing group update."))
            let result = try await appState.marmot.removeMembersDetailed(
                accountRef: accountRef,
                groupIdHex: viewModel.group.groupIdHex,
                memberRefs: [member.memberIdHex]
            )
            viewModel.applyGroupMutation(result)
            await refreshVisibleMlsState()
            Haptics.success()
            appState.present(.warning("Member removed", message: publishMessage(for: result.summary)))
        } catch {
            await refreshAfterFailedMutation()
            handleActionError(error, title: "Couldn't remove member")
        }
    }

    private func setAdmin(member: GroupMemberDetailsFfi, admin: Bool) async {
        guard let accountRef = appState.activeAccountRef else { return }
        membershipActionInFlight = true
        defer { membershipActionInFlight = false }
        viewModel.applyOptimisticAdminStatus(memberIdHex: member.memberIdHex, isAdmin: admin)
        appState.present(.warning(
            admin ? "Making admin…" : "Removing admin…",
            message: "Publishing group update."
        ))
        do {
            let result: GroupMutationResultFfi
            if admin {
                result = try await appState.marmot.promoteAdminDetailed(
                    accountRef: accountRef,
                    groupIdHex: viewModel.group.groupIdHex,
                    memberRef: member.memberIdHex
                )
            } else {
                result = try await appState.marmot.demoteAdminDetailed(
                    accountRef: accountRef,
                    groupIdHex: viewModel.group.groupIdHex,
                    memberRef: member.memberIdHex
                )
            }
            viewModel.applyGroupMutation(result)
            await refreshVisibleMlsState()
            Haptics.success()
            appState.present(
                admin
                    ? .success("Made admin", message: publishMessage(for: result.summary))
                    : .warning("Admin removed", message: publishMessage(for: result.summary))
            )
        } catch {
            await refreshAfterFailedMutation()
            handleActionError(error, title: "Couldn't change admin")
        }
    }

    private func selfDemote() async {
        guard let accountRef = appState.activeAccountRef else { return }
        membershipActionInFlight = true
        defer { membershipActionInFlight = false }
        if let myAccountId = viewModel.managementState?.myAccountIdHex {
            viewModel.applyOptimisticAdminStatus(memberIdHex: myAccountId, isAdmin: false)
        }
        appState.present(.warning("Stepping down…", message: "Publishing group update."))
        do {
            let result = try await appState.marmot.selfDemoteAdminDetailed(
                accountRef: accountRef,
                groupIdHex: viewModel.group.groupIdHex
            )
            viewModel.applyGroupMutation(result)
            await refreshVisibleMlsState()
            Haptics.success()
            appState.present(.warning("You stepped down as admin", message: publishMessage(for: result.summary)))
        } catch {
            await refreshAfterFailedMutation()
            handleActionError(error, title: "Couldn't step down")
        }
    }

    private func rename() async {
        guard let accountRef = appState.activeAccountRef else { return }
        let name = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            appState.present(.warning("Updating group name…", message: "Publishing group update."))
            let summary = try await appState.marmot.updateGroupProfile(
                accountRef: accountRef,
                groupIdHex: viewModel.group.groupIdHex,
                name: name,
                description: nil
            )
            await viewModel.refreshGroupManagement()
            await refreshVisibleMlsState()
            Haptics.success()
            appState.present(.success("Group name updated", message: publishMessage(for: summary)))
        } catch {
            await refreshAfterFailedMutation()
            Haptics.error()
            actionError = error.localizedDescription
            appState.present(.error("Couldn't rename group", message: error.localizedDescription))
        }
    }

    private func setArchived(_ archived: Bool) async {
        guard let accountRef = appState.activeAccountRef else { return }
        do {
            let record = try appState.marmot.setGroupArchived(
                accountRef: accountRef,
                groupIdHex: viewModel.group.groupIdHex,
                archived: archived
            )
            viewModel.applyGroupRecord(record)
            await refreshVisibleMlsState()
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
        guard GroupManagementPresentation.canLeave(
            state: viewModel.managementState,
            fallbackIsLastAdmin: viewModel.isLastAdmin
        ) else {
            actionError = GroupManagementPresentation.leaveFooter(
                state: viewModel.managementState,
                fallbackIsLastAdmin: viewModel.isLastAdmin
            )
            return
        }
        membershipActionInFlight = true
        defer { membershipActionInFlight = false }
        do {
            if GroupManagementPresentation.shouldSelfDemoteBeforeLeave(state: viewModel.managementState) {
                if let myAccountId = viewModel.managementState?.myAccountIdHex {
                    viewModel.applyOptimisticAdminStatus(memberIdHex: myAccountId, isAdmin: false)
                }
                appState.present(.warning("Stepping down before leaving…", message: "Publishing group update."))
                let result = try await appState.marmot.selfDemoteAdminDetailed(
                    accountRef: accountRef,
                    groupIdHex: viewModel.group.groupIdHex
                )
                viewModel.applyGroupMutation(result)
                await refreshVisibleMlsState()
            }
            appState.present(.warning("Leaving group…", message: "Publishing group update."))
            _ = try await appState.marmot.leaveGroup(
                accountRef: accountRef,
                groupIdHex: viewModel.group.groupIdHex
            )
            Haptics.warning()
            appState.present(.warning("You left the group"))
            dismiss()
        } catch {
            await refreshAfterFailedMutation()
            handleActionError(error, title: "Couldn't leave group")
        }
    }

    private func handleActionError(_ error: Error, title: String) {
        let message = actionMessage(for: error)
        Haptics.error()
        actionError = message
        appState.present(.error(title, message: message))
    }

    private func actionMessage(for error: Error) -> String {
        guard let marmotError = error as? MarmotKitError else {
            return error.localizedDescription
        }
        switch marmotError {
        case .NotGroupAdmin:
            return "Only admins can manage group members."
        case .AdminCannotSelfRemove:
            return "Step down as admin before leaving the group."
        case .WouldRemoveLastAdmin:
            return "Make another member an admin before removing the last admin."
        case .MemberNotInGroup:
            return "That member is no longer in this group."
        case .AlreadyAdmin:
            return "That member is already an admin."
        case .NotAdmin:
            return "That member is not an admin."
        case .MissingKeyPackage(let account):
            return "\(IdentityFormatter.short(account)) hasn't published a compatible key package yet."
        default:
            return marmotError.localizedDescription
        }
    }

    private func publishMessage(for summary: SendSummaryFfi) -> String {
        guard summary.published > 0 else { return "Saved locally." }
        let suffix = summary.published == 1 ? "" : "s"
        return "Published \(summary.published) update\(suffix)."
    }

    private func refreshAfterFailedMutation() async {
        _ = await viewModel.refreshGroupManagement()
        await refreshVisibleMlsState()
    }

    private func refreshVisibleMlsState() async {
        guard appState.developerMode else {
            mlsState = nil
            return
        }
        guard let accountRef = appState.activeAccountRef else { return }
        mlsState = try? await appState.marmot.groupMlsState(
            accountRef: accountRef,
            groupIdHex: viewModel.group.groupIdHex
        )
    }
}

private enum GroupDetailsActionError: LocalizedError {
    case noActiveAccount

    var errorDescription: String? {
        switch self {
        case .noActiveAccount:
            "No active account is selected."
        }
    }
}

private enum GroupActionHelp {
    case stepDown
    case archive
    case leave(message: String)

    var title: String {
        switch self {
        case .stepDown:
            return "Step Down as Admin"
        case .archive:
            return "Archive Group"
        case .leave:
            return "Leave Group"
        }
    }

    var message: String {
        switch self {
        case .stepDown:
            return "You'll stay in the group, but another admin will need to restore your admin status."
        case .archive:
            return "Archiving hides the group from your main chats list. It doesn't change your membership or notify anyone."
        case .leave(let message):
            return message
        }
    }
}
