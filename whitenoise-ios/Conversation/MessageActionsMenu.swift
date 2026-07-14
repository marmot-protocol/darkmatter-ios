import SwiftUI
import MarmotKit

/// Free-floating actions pane shown in a popover anchored under a long-pressed
/// message: a row of the most-recent reaction emojis with a full-picker
/// button, then message actions such as reply, forward, edit, info, and delete.
struct MessageActionsMenu: View {
    let canInteract: Bool
    let canForward: Bool
    let canEdit: Bool
    let canViewEditHistory: Bool
    let canDelete: Bool
    let quickReactions: [String]
    let onReact: (String) -> Void
    let onReply: () -> Void
    let onCopy: () -> Void
    let onForward: () -> Void
    let onEdit: () -> Void
    let onViewEditHistory: () -> Void
    let onInfo: () -> Void
    let onSelect: () -> Void
    let onDelete: () -> Void
    let onMoreEmoji: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if canInteract {
                reactionRow
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

                Divider()
            }

            if canInteract {
                actionRow("Reply", systemImage: "arrowshape.turn.up.left", action: onReply)
                Divider().padding(.leading, 46)
            }
            actionRow("Copy", systemImage: "doc.on.doc", action: onCopy)
            if canForward {
                Divider().padding(.leading, 46)
                actionRow("Forward", systemImage: "arrowshape.turn.up.right", action: onForward)
            }
            if canEdit {
                Divider().padding(.leading, 46)
                actionRow("Edit", systemImage: "pencil", action: onEdit)
            }
            if canViewEditHistory {
                Divider().padding(.leading, 46)
                actionRow("View edit history", systemImage: "clock.arrow.circlepath", action: onViewEditHistory)
            }
            Divider().padding(.leading, 46)
            actionRow("Message info", systemImage: "info.circle", action: onInfo)
            Divider().padding(.leading, 46)
            actionRow("Select", systemImage: "checkmark.circle", action: onSelect)

            if canDelete {
                Divider().padding(.leading, 46)
                actionRow("Delete", systemImage: "trash", role: .destructive, action: onDelete)
            }
        }
        .frame(width: 280)
        .presentationCompactAdaptation(.popover)
    }

    private var reactionRow: some View {
        HStack(spacing: 9) {
            ForEach(quickReactions, id: \.self) { emoji in
                Button {
                    onReact(emoji)
                } label: {
                    Text(emoji).font(.title3)
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 4)
            Divider().frame(height: 26)
            Button {
                onMoreEmoji()
            } label: {
                Image(systemName: "face.smiling")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More emoji")
        }
    }

    private func actionRow(
        _ title: LocalizedStringKey,
        systemImage: String,
        role: ButtonRole? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(spacing: 12) {
                Image(systemName: systemImage)
                    .frame(width: 22)
                Text(title)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(.rect)
        }
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
    }
}
