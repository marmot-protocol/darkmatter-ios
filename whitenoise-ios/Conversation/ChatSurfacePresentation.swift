import SwiftUI

enum ConversationDateHeader {
    static func dayStart(
        timestamp: UInt64,
        calendar: Calendar = .autoupdatingCurrent
    ) -> Date {
        calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(timestamp)))
    }

    static func label(
        timestamp: UInt64,
        now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        if calendar.isDate(date, inSameDayAs: now) {
            return L10n.string("Today")
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday)
        {
            return L10n.string("Yesterday")
        }
        return date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .omitted)
                .locale(locale)
        )
    }
}

nonisolated enum MessageSelectionPolicy {
    static let maximumForwardCount = 30

    static func canForward(selectedCount: Int, allForwardable: Bool) -> Bool {
        selectedCount > 0
            && selectedCount <= maximumForwardCount
            && allForwardable
    }

    static func canDelete(selectedCount: Int, allDeletable: Bool) -> Bool {
        selectedCount > 0 && allDeletable
    }

    static func canCopy(selectedCount: Int, anyHasText: Bool) -> Bool {
        selectedCount > 0 && anyHasText
    }

    /// Joins the copyable bodies of the selected messages with blank lines,
    /// in the order given (callers pass them chronologically). Empty bodies
    /// (media-only rows) are dropped so the clipboard holds only real text.
    static func combinedCopyText(_ bodies: [String]) -> String {
        bodies
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

nonisolated enum ChatBubbleMetrics {
    static let regularMaximumWidth: CGFloat = 560
    static let compactOppositeInset: CGFloat = 48
    static let regularOppositeInset: CGFloat = 64
    static let horizontalInset: CGFloat = 12
    static let verticalInset: CGFloat = 8
    static let cornerRadius: CGFloat = 18
}

nonisolated enum MessageBubbleTextLayout {
    static func usesInlineFooter(text: String, isCollapsed: Bool) -> Bool {
        guard !isCollapsed else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
    }
}

struct MessageFooterPresentation: Equatable {
    let systemImage: String?
    let accessibilityLabel: String?
    let isFailure: Bool

    static func value(for status: MessageStatus, isFromMe: Bool) -> Self {
        guard isFromMe || status == .streaming else {
            return Self(systemImage: nil, accessibilityLabel: nil, isFailure: false)
        }

        switch status {
        case .received:
            return Self(systemImage: nil, accessibilityLabel: nil, isFailure: false)
        case .sending:
            return Self(systemImage: "clock", accessibilityLabel: L10n.string("Sending…"), isFailure: false)
        case .sent:
            return Self(systemImage: "checkmark", accessibilityLabel: L10n.string("Sent"), isFailure: false)
        case .failed:
            return Self(
                systemImage: "exclamationmark.circle.fill",
                accessibilityLabel: L10n.string("Not delivered"),
                isFailure: true
            )
        case .streaming:
            return Self(
                systemImage: "waveform",
                accessibilityLabel: L10n.string("Streaming…"),
                isFailure: false
            )
        }
    }
}

enum MessageMediaUploadPresentation {
    static func showsIndicator(status: MessageStatus, items: [MessageMediaAttachment]) -> Bool {
        guard status == .sending else { return false }
        return items.contains { $0.reference == nil && $0.localData != nil }
    }
}

nonisolated struct ReactionSummaryPresentation: Equatable {
    let emojis: [String]
    let totalCount: Int
    let mine: Bool

    static func value(
        from reactions: [ConversationViewModel.ReactionTally],
        maximumVisibleEmojis: Int = 3
    ) -> Self? {
        guard maximumVisibleEmojis > 0, !reactions.isEmpty else { return nil }

        let sorted = reactions.sorted {
            if $0.mine != $1.mine { return $0.mine && !$1.mine }
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.emoji < $1.emoji
        }
        return Self(
            emojis: sorted.prefix(maximumVisibleEmojis).map(\.emoji),
            totalCount: sorted.reduce(0) { $0 + $1.count },
            mine: reactions.contains(where: \.mine)
        )
    }
}

/// A tombstone keeps its timestamp — a removed message still has a place in
/// the timeline — but drops the delivery checkmark, which says nothing once
/// the message is gone.
nonisolated enum MessageTombstonePresentation {
    static func showsDeliveryStatus(isDeleted: Bool) -> Bool { !isDeleted }
}

struct MessageMetadataFooter: View {
    let time: String
    let isEdited: Bool
    let status: MessageStatus
    let isFromMe: Bool
    let usesLightForeground: Bool
    var showsDeliveryStatus: Bool = true
    var onViewEditHistory: (() -> Void)?

    private var presentation: MessageFooterPresentation {
        .value(for: status, isFromMe: isFromMe)
    }

    private var foreground: Color {
        if presentation.isFailure { return .red }
        return usesLightForeground ? .white.opacity(0.76) : .secondary
    }

    var body: some View {
        HStack(spacing: 3) {
            Text(time)
            if isEdited {
                Text("·")
                if let onViewEditHistory {
                    Button(L10n.string("Edited"), action: onViewEditHistory)
                        .buttonStyle(.plain)
                } else {
                    Text(L10n.string("Edited"))
                }
            }
            if showsDeliveryStatus, let systemImage = presentation.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityLabel(presentation.accessibilityLabel ?? "")
            }
        }
        .font(.caption2)
        .foregroundStyle(foreground)
        .fixedSize(horizontal: true, vertical: true)
    }
}
