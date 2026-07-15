import SwiftUI
import MarmotKit

/// Step two of New Group: optional name and description, an optional
/// disappearing-messages preset applied after creation, and a preview of the
/// selected people. Group-name semantics are unchanged — an unnamed group
/// with one member renders as a direct message.
struct NewGroupSetupView: View {
    @Environment(AppState.self) private var appState
    @Bindable var model: NewChatFlowViewModel
    let onOpen: (String) -> Void

    @State private var name = ""
    @State private var groupDescription = ""
    @State private var retentionSeconds: UInt64 = 0

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(.tint.opacity(0.12))
                        Image(systemName: "person.2.fill")
                            .foregroundStyle(.tint)
                    }
                    .frame(width: 52, height: 52)
                    .accessibilityHidden(true)
                    TextField("Group name (optional)", text: $name)
                        .disabled(model.isCreatingGroup)
                }
                .padding(.vertical, 4)
            } footer: {
                Text("Groups without a name show their members instead.")
            }

            Section {
                TextField("Description", text: $groupDescription, axis: .vertical)
                    .lineLimit(2...4)
                    .disabled(model.isCreatingGroup)
            } footer: {
                Text("Everyone in the group will see this description.")
            }

            Section {
                Picker("Disappearing messages", selection: $retentionSeconds) {
                    ForEach(GroupRetentionPresentation.presetSeconds, id: \.self) { seconds in
                        Text(GroupRetentionPresentation.label(seconds: seconds))
                            .tag(seconds)
                    }
                }
                .disabled(model.isCreatingGroup)
            } footer: {
                if retentionSeconds > 0 {
                    Text("Messages are deleted for everyone after the selected time.")
                }
            }

            Section {
                ForEach(model.groupSelection.members, id: \.accountIdHex) { member in
                    RecipientRow(accountIdHex: member.accountIdHex, npub: member.npub) {
                        EmptyView()
                    }
                }
            } header: {
                Text(L10n.plural("%lld members", Int64(model.groupSelection.count)))
            }

            if let error = model.groupCreateError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("New Group")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(model.isCreatingGroup ? L10n.string("Creating…") : L10n.string("Create")) {
                    Task {
                        await model.createGroup(
                            name: name,
                            description: groupDescription,
                            retentionSeconds: retentionSeconds,
                            using: appState,
                            onOpen: onOpen
                        )
                    }
                }
                .disabled(!canCreate)
            }
        }
        .navigationBarBackButtonHidden(model.isCreatingGroup)
    }

    private var canCreate: Bool {
        AddMembersPresentation.canCreate(
            stagedCount: model.groupSelection.count,
            isCreating: model.isCreatingGroup,
            hasActiveAccount: appState.activeAccountRef != nil
        )
    }
}
