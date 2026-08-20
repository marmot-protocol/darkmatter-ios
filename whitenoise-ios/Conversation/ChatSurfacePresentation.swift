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

enum MessageBubblePalette {
    static let sentBackground = Color.primary
    static let sentForeground = Color(uiColor: .systemBackground)
    static let receivedBackground = Color(uiColor: .systemGray5)
    static let receivedForeground = Color(uiColor: .label)
}

nonisolated enum MessageMetadataRowArrangement {
    static func timestampOnLeadingEdge(isFromMe: Bool, hasReactions: Bool) -> Bool {
        isFromMe != hasReactions
    }
}

nonisolated enum MessageBubbleChromeSizing {
    static func width(
        proposedWidth: CGFloat?,
        bubbleWidth: CGFloat,
        metadataWidth: CGFloat
    ) -> CGFloat {
        let idealWidth = max(0, bubbleWidth, metadataWidth)
        guard let proposedWidth, proposedWidth.isFinite else { return idealWidth }
        return min(max(0, proposedWidth), idealWidth)
    }

    static func height(
        bubbleHeight: CGFloat,
        metadataHeight: CGFloat,
        spacing: CGFloat
    ) -> CGFloat {
        max(0, bubbleHeight) + max(0, spacing) + max(0, metadataHeight)
    }
}

struct MessageBubbleChromeLayout: Layout {
    let isFromMe: Bool
    var spacing: CGFloat = 3

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard subviews.count == 2 else { return .zero }

        let widthProposal = ProposedViewSize(width: proposal.width, height: nil)
        let bubbleSize = subviews[0].sizeThatFits(widthProposal)
        let metadataIdealSize = subviews[1].sizeThatFits(.unspecified)
        let width = MessageBubbleChromeSizing.width(
            proposedWidth: proposal.width,
            bubbleWidth: bubbleSize.width,
            metadataWidth: metadataIdealSize.width
        )
        let resolvedProposal = ProposedViewSize(width: width, height: nil)
        let resolvedBubbleSize = subviews[0].sizeThatFits(resolvedProposal)
        let resolvedMetadataSize = subviews[1].sizeThatFits(resolvedProposal)

        return CGSize(
            width: width,
            height: MessageBubbleChromeSizing.height(
                bubbleHeight: resolvedBubbleSize.height,
                metadataHeight: resolvedMetadataSize.height,
                spacing: spacing
            )
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard subviews.count == 2 else { return }

        let resolvedProposal = ProposedViewSize(width: bounds.width, height: nil)
        let bubbleSize = subviews[0].sizeThatFits(resolvedProposal)
        let bubbleX = isFromMe ? bounds.maxX - bubbleSize.width : bounds.minX
        subviews[0].place(
            at: CGPoint(x: bubbleX, y: bounds.minY),
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bubbleSize.width, height: bubbleSize.height)
        )
        subviews[1].place(
            at: CGPoint(x: bounds.minX, y: bounds.minY + bubbleSize.height + spacing),
            anchor: .topLeading,
            proposal: resolvedProposal
        )
    }
}

nonisolated enum SingleEmojiMessagePresentation {
    static let fontSize: CGFloat = 64

    static func emoji(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 1, let character = trimmed.first else { return nil }

        let scalars = character.unicodeScalars
        let hasEmojiCapableScalar = scalars.contains { $0.properties.isEmoji }
        let requestsEmojiRendering = scalars.contains {
            $0.properties.isEmojiPresentation
                || $0.value == 0xFE0F
                || $0.value == 0x20E3
        }

        guard hasEmojiCapableScalar, requestsEmojiRendering else { return nil }
        return trimmed
    }
}

nonisolated enum MessageExpirationPresentation {
    enum Detail: Equatable {
        case expired
        case relative(Date)
        case absolute(Date)
    }

    static let systemImage = "timer"
    static let relativeTimeHorizon: TimeInterval = 24 * 60 * 60

    static func showsIndicator(retentionSeconds: UInt64?, expiresAt: UInt64?) -> Bool {
        guard let retentionSeconds, retentionSeconds > 0,
              let expiresAt, expiresAt > 0
        else { return false }

        return true
    }

    static func detail(expiresAt: UInt64?, now: Date = Date()) -> Detail? {
        guard let expiresAt, expiresAt > 0 else { return nil }
        let expirationDate = Date(timeIntervalSince1970: TimeInterval(expiresAt))
        let remaining = expirationDate.timeIntervalSince(now)

        if remaining <= 0 {
            return .expired
        }
        if remaining <= relativeTimeHorizon {
            return .relative(expirationDate)
        }
        return .absolute(expirationDate)
    }

    @MainActor
    static func detailLabel(
        expiresAt: UInt64?,
        now: Date = Date(),
        locale: Locale = AppLanguage.currentLocale
    ) -> String? {
        switch detail(expiresAt: expiresAt, now: now) {
        case .expired:
            return L10n.formatted("Expired", arguments: [], locale: locale)
        case .relative(let expirationDate):
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.dateTimeStyle = .numeric
            formatter.unitsStyle = .full
            return formatter.localizedString(for: expirationDate, relativeTo: now)
        case .absolute(let expirationDate):
            let style = Date.FormatStyle(date: .long, time: .standard).locale(locale)
            return expirationDate.formatted(style)
        case nil:
            return nil
        }
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
    var showsDeliveryStatus: Bool = true
    var showsExpirationTimer: Bool = false
    var onViewEditHistory: (() -> Void)?

    private var presentation: MessageFooterPresentation {
        .value(for: status, isFromMe: isFromMe)
    }

    private var resolvedForeground: Color {
        presentation.isFailure ? .red : .secondary
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
            if showsExpirationTimer {
                Image(systemName: MessageExpirationPresentation.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityLabel(L10n.string("Disappearing messages"))
            }
            if showsDeliveryStatus, let systemImage = presentation.systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityLabel(presentation.accessibilityLabel ?? "")
            }
        }
        .font(.caption2)
        .foregroundStyle(resolvedForeground)
        .fixedSize(horizontal: true, vertical: true)
    }
}
