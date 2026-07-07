import SwiftUI

nonisolated enum LocalizedNumberLabel {
    static func decimal(_ value: UInt64, locale: Locale = AppLanguage.currentLocale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        return formatter.string(from: NSNumber(value: value))
            ?? String(format: "%llu", locale: locale, value)
    }
}

/// Compact capsule showing an unread-message count, capped at "99+". Shared by
/// the chat list rows and the Profiles switch-account rows so both stay
/// visually and behaviorally identical. `label` is static so its "99+" cap can
/// be unit-tested without rendering the view.
struct UnreadCountBadge: View {
    let count: UInt64

    var body: some View {
        Text(Self.label(for: count))
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.accentColor))
            .accessibilityLabel(L10n.plural("%llu unread messages", count))
    }

    /// Compact count label, capped at "99+" so the capsule keeps a small,
    /// fixed width no matter how many messages are unread.
    static func label(for count: UInt64, locale: Locale = AppLanguage.currentLocale) -> String {
        if count > 99 {
            return L10n.formatted(
                "%@+",
                arguments: [LocalizedNumberLabel.decimal(99, locale: locale)],
                locale: locale
            )
        }
        return LocalizedNumberLabel.decimal(count, locale: locale)
    }
}
