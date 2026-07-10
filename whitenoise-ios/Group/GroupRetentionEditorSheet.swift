import SwiftUI

/// Admin editor for the group's disappearing-messages timer. Enabling or
/// shortening the timer asks for confirmation first because the engine prunes
/// existing messages older than the new window immediately.
struct GroupRetentionEditorSheet: View {
    let currentSeconds: UInt64
    let onSubmit: (UInt64) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Selection
    @State private var customValueDraft: String
    @State private var customUnit: GroupRetentionPresentation.CustomUnit
    @State private var showPruneConfirmation = false
    @State private var isSubmitting = false

    private enum Selection: Hashable {
        case preset(UInt64)
        case custom
    }

    init(currentSeconds: UInt64, onSubmit: @escaping (UInt64) async -> Bool) {
        self.currentSeconds = currentSeconds
        self.onSubmit = onSubmit
        let draft = GroupRetentionPresentation.customDraft(forSeconds: currentSeconds)
        _selection = State(initialValue: GroupRetentionPresentation.presetSeconds.contains(currentSeconds)
            ? .preset(currentSeconds)
            : .custom)
        _customValueDraft = State(initialValue: draft.value)
        _customUnit = State(initialValue: draft.unit)
    }

    private var draftSeconds: UInt64? {
        switch selection {
        case .preset(let seconds):
            return seconds
        case .custom:
            return GroupRetentionPresentation.customSeconds(value: customValueDraft, unit: customUnit)
        }
    }

    private var isCustomDraftInvalid: Bool {
        selection == .custom
            && !customValueDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draftSeconds == nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(GroupRetentionPresentation.presetSeconds, id: \.self) { seconds in
                        optionRow(
                            title: GroupRetentionPresentation.label(seconds: seconds),
                            isSelected: selection == .preset(seconds)
                        ) {
                            selection = .preset(seconds)
                        }
                    }
                    optionRow(
                        title: L10n.string("Custom"),
                        isSelected: selection == .custom
                    ) {
                        selection = .custom
                    }
                } footer: {
                    Text("Messages are deleted for everyone after the selected time.")
                }

                if selection == .custom {
                    Section {
                        TextField(L10n.string("Duration"), text: $customValueDraft)
                            .keyboardType(.numberPad)
                        Picker(L10n.string("Unit"), selection: $customUnit) {
                            ForEach(GroupRetentionPresentation.CustomUnit.allCases, id: \.self) { unit in
                                Text(unit.label)
                            }
                        }
                    } footer: {
                        if isCustomDraftInvalid {
                            Text(L10n.formatted(
                                "Enter a duration between %@ and %@.",
                                GroupRetentionPresentation.label(seconds: GroupRetentionPresentation.minCustomSeconds),
                                GroupRetentionPresentation.label(seconds: GroupRetentionPresentation.maxCustomSeconds)
                            ))
                            .foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("Disappearing messages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSubmitting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(isSubmitting || draftSeconds == nil || draftSeconds == currentSeconds)
                }
            }
            .alert("Delete older messages?", isPresented: $showPruneConfirmation) {
                Button(L10n.string("Set Timer"), role: .destructive) {
                    if let seconds = draftSeconds {
                        submit(seconds)
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text(L10n.formatted(
                    "This timer also applies to messages already in the chat. Everything older than %@ will be deleted immediately.",
                    GroupRetentionPresentation.label(seconds: draftSeconds ?? currentSeconds)
                ))
            }
            .interactiveDismissDisabled(isSubmitting)
        }
    }

    private func optionRow(title: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isSubmitting)
    }

    private func save() {
        // Abort on invalid pending input before starting async work.
        guard let seconds = draftSeconds, seconds != currentSeconds else { return }
        if GroupRetentionPresentation.requiresRetroactivePruneConfirmation(
            currentSeconds: currentSeconds,
            newSeconds: seconds
        ) {
            showPruneConfirmation = true
        } else {
            submit(seconds)
        }
    }

    private func submit(_ seconds: UInt64) {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task {
            let succeeded = await onSubmit(seconds)
            isSubmitting = false
            if succeeded {
                dismiss()
            }
        }
    }
}
