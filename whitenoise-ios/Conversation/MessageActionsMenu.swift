import SwiftUI
import MarmotKit

nonisolated enum MessageActionsPresentation {
    static let actionHeight: CGFloat = 50
    static let reactionHeight: CGFloat = 56
    static let verticalChrome: CGFloat = 40

    static func estimatedHeight(
        canRetry: Bool,
        canInteract: Bool,
        canForward: Bool,
        canEdit: Bool,
        canViewEditHistory: Bool,
        canDelete: Bool
    ) -> CGFloat {
        var actionCount = 3 // Copy, Info, and Select.
        if canRetry { actionCount += 1 }
        if canInteract { actionCount += 1 }
        if canForward { actionCount += 1 }
        if canEdit { actionCount += 1 }
        if canViewEditHistory { actionCount += 1 }
        if canDelete { actionCount += 1 }
        return CGFloat(actionCount) * actionHeight
            + (canInteract ? reactionHeight : 0)
            + verticalChrome
    }
}

/// Free-floating actions pane shown in a popover anchored under a long-pressed
/// message: a row of the most-recent reaction emojis with a full-picker
/// button, then message actions such as reply, forward, edit, info, and delete.
struct MessageActionsMenu: View {
    let canRetry: Bool
    let canInteract: Bool
    let canForward: Bool
    let canEdit: Bool
    let canViewEditHistory: Bool
    let canDelete: Bool
    let quickReactions: [String]
    let selectedReaction: String?
    let onRetry: () -> Void
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
        VStack(alignment: .leading, spacing: 12) {
            if canInteract { reactionRow }

            VStack(spacing: 0) {
                if canRetry {
                    actionRow("Retry send", systemImage: "arrow.clockwise", action: onRetry)
                }
                if canInteract {
                    actionRow("Reply", systemImage: "arrowshape.turn.up.left", action: onReply)
                }
                if canForward {
                    actionRow("Forward", systemImage: "arrowshape.turn.up.right", action: onForward)
                }
                if canEdit {
                    actionRow("Edit", systemImage: "pencil", action: onEdit)
                }
                if canViewEditHistory {
                    actionRow("View edit history", systemImage: "clock.arrow.circlepath", action: onViewEditHistory)
                }
                actionRow("Copy", systemImage: "doc.on.doc", action: onCopy)
                actionRow("Select", systemImage: "checkmark.circle", action: onSelect)
                actionRow("Info", systemImage: "info.circle", action: onInfo)

                if canDelete {
                    actionRow("Delete", systemImage: "trash", role: .destructive, action: onDelete)
                }
            }
            .padding(.vertical, 10)
            .background(.regularMaterial, in: .rect(cornerRadius: 28))
            .overlay {
                RoundedRectangle(cornerRadius: 28)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
        }
        .padding(8)
        .frame(width: 266)
        .presentationBackground(.clear)
        .presentationCompactAdaptation(.popover)
    }

    private var reactionRow: some View {
        HStack(spacing: 0) {
            ForEach(displayedQuickReactions, id: \.self) { emoji in
                Button {
                    onReact(emoji)
                } label: {
                    Text(emoji)
                        .font(.system(size: 27))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background {
                            if selectedReaction == emoji {
                                Circle().fill(Color(uiColor: .systemFill))
                                    .frame(width: 38, height: 38)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(selectedReaction == emoji ? "Selected" : "")
                .accessibilityAddTraits(selectedReaction == emoji ? .isSelected : [])
            }
            Button {
                onMoreEmoji()
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(Color(uiColor: .tertiarySystemFill), in: .circle)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More reactions")
        }
        .padding(6)
        .background(.regularMaterial, in: .capsule)
        .overlay {
            Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private var displayedQuickReactions: [String] {
        guard let selectedReaction, !quickReactions.contains(selectedReaction) else {
            return quickReactions
        }
        return quickReactions + [selectedReaction]
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
                    .frame(width: 24)
                Text(title)
                Spacer()
            }
            .font(.body)
            .padding(.horizontal, 22)
            .frame(minHeight: 50)
            .contentShape(.rect)
        }
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
    }
}
