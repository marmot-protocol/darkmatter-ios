import SwiftUI
import MarmotKit

/// Step two of New Group: name card, disappearing-messages preset, and the
/// removable member rail. Group-name semantics are unchanged — an unnamed
/// group with one member renders as a direct message.
struct NewGroupSetupView: View {
    @Environment(AppState.self) private var appState
    @Bindable var model: NewChatFlowViewModel
    let onOpen: (String) -> Void

    @State private var name = ""
    @State private var retentionSeconds: UInt64 = 0
    @State private var showRetentionPicker = false

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(.tint.opacity(0.12))
                        Image(systemName: "camera")
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
                Button {
                    showRetentionPicker = true
                } label: {
                    LabeledContent("Disappearing messages") {
                        HStack(spacing: 6) {
                            Text(GroupRetentionPresentation.label(seconds: retentionSeconds))
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(model.isCreatingGroup)
            }

            Section {
                SelectedRecipientRail(members: model.groupSelection.members) { member in
                    model.groupSelection.remove(accountIdHex: member.accountIdHex)
                }
                .disabled(model.isCreatingGroup)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
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
        .toolbarRole(.editor)
        .navigationDestination(isPresented: $showRetentionPicker) {
            RetentionPresetPickerView(selection: $retentionSeconds)
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(model.isCreatingGroup ? L10n.string("Creating…") : L10n.string("Create")) {
                    Task {
                        await model.createGroup(
                            name: name,
                            description: "",
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

/// Preset picker for the create flow: no prune warning needed because the
/// group doesn't exist yet. Custom durations stay in the details editor.
struct RetentionPresetPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: UInt64

    var body: some View {
        Form {
            Section {
                ForEach(GroupRetentionPresentation.presetSeconds, id: \.self) { seconds in
                    Button {
                        selection = seconds
                        dismiss()
                    } label: {
                        HStack {
                            Text(GroupRetentionPresentation.label(seconds: seconds))
                                .foregroundStyle(.primary)
                            Spacer()
                            if selection == seconds {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text(selection == 0
                    ? "Messages are kept until you delete them."
                    : "Messages are deleted for everyone after the selected time.")
            }
        }
        .navigationTitle("Disappearing messages")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
    }
}
