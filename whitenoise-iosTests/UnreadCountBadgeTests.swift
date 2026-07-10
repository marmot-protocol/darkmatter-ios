import Testing
import Foundation
@testable import whitenoise_ios

/// `UnreadCountBadge` renders a compact count capped at "99+". Locks that
/// boundary without rendering the view.
struct UnreadCountBadgeTests {
    @Test func showsExactCountUpToNinetyNine() {
        let locale = Locale(identifier: "en_US")

        #expect(UnreadCountBadge.label(for: 1, locale: locale) == "1")
        #expect(UnreadCountBadge.label(for: 42, locale: locale) == "42")
        #expect(UnreadCountBadge.label(for: 99, locale: locale) == "99")
    }

    @Test func capsAtNinetyNinePlusOnceOverNinetyNine() {
        let locale = Locale(identifier: "en_US")

        #expect(UnreadCountBadge.label(for: 100, locale: locale) == "99+")
        #expect(UnreadCountBadge.label(for: 1000, locale: locale) == "99+")
        #expect(UnreadCountBadge.label(for: .max, locale: locale) == "99+")
    }

    @Test func localizesVisibleDigits() {
        let locale = Locale(identifier: "ar_EG")

        #expect(UnreadCountBadge.label(for: 42, locale: locale) == String(
            format: "%llu",
            locale: locale,
            UInt64(42)
        ))
        #expect(UnreadCountBadge.label(for: 100, locale: locale) == L10n.formatted(
            "%@+",
            arguments: [LocalizedNumberLabel.decimal(99, locale: locale)],
            locale: locale
        ))
        #expect(UnreadCountBadge.label(for: 42, locale: locale) != "42")
    }

    @Test func mentionBadgeUsesTheAtIcon() {
        #expect(MentionBadgePresentation.systemImageName == "at")
    }
}
