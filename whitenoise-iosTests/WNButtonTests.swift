import SwiftUI
import Testing
@testable import whitenoise_ios

struct WNButtonTests {
    @Test func accentIsMonochromeAgainstTheColorScheme() {
        #expect(WNButton.Metrics.accent(for: .light) == .black)
        #expect(WNButton.Metrics.accent(for: .dark) == .white)
    }

    @Test func primaryContentInvertsTheFilledAccent() {
        #expect(
            WNButton.Metrics.contentColor(
                emphasis: .primary,
                colorScheme: .light,
                isEnabled: true
            ) == .white
        )
        #expect(
            WNButton.Metrics.contentColor(
                emphasis: .primary,
                colorScheme: .dark,
                isEnabled: true
            ) == .black
        )
    }

    @Test func secondaryContentMatchesTheAccent() {
        #expect(
            WNButton.Metrics.contentColor(
                emphasis: .secondary,
                colorScheme: .light,
                isEnabled: true
            ) == WNButton.Metrics.accent(for: .light)
        )
        #expect(
            WNButton.Metrics.contentColor(
                emphasis: .secondary,
                colorScheme: .dark,
                isEnabled: true
            ) == WNButton.Metrics.accent(for: .dark)
        )
    }

    @Test func disabledContentDimsForBothEmphasesAndSchemes() {
        for emphasis in [WNButton.Emphasis.primary, .secondary] {
            for colorScheme in [ColorScheme.light, .dark] {
                #expect(
                    WNButton.Metrics.contentColor(
                        emphasis: emphasis,
                        colorScheme: colorScheme,
                        isEnabled: false
                    ) == .secondary
                )
            }
        }
    }

    @Test func fallbackLabelMinHeightClearsTheAppleMinimumTapTarget() {
        #expect(WNButton.Metrics.fallbackLabelMinHeight >= 44)
    }

    @Test func onlyTheLargeSizeClaimsTheFullWidth() {
        #expect(WNButton.Metrics.stretches(.large))
        #expect(!WNButton.Metrics.stretches(.compact))
    }

    @Test func compactDropsBelowTheCallToActionControlSize() {
        #expect(WNButton.Metrics.controlSize(for: .large) == .extraLarge)
        #expect(WNButton.Metrics.controlSize(for: .compact) < .extraLarge)
    }
}
