import SwiftUI
import Testing
@testable import whitenoise_ios

@MainActor
struct AppearanceThemeTests {
    @Test func persistedRawValuesStayStable() {
        // Stored in UserDefaults, so renaming a case is a breaking change.
        #expect(AppearanceTheme.system.rawValue == "system")
        #expect(AppearanceTheme.light.rawValue == "light")
        #expect(AppearanceTheme.dark.rawValue == "dark")
        #expect(AppearanceTheme.trueBlack.rawValue == "trueBlack")
    }

    @Test func everyThemeRoundTripsThroughItsRawValue() {
        for theme in AppearanceTheme.allCases {
            #expect(AppearanceTheme.resolved(rawValue: theme.rawValue) == theme)
        }
    }

    @Test func unknownAndMissingRawValuesFallBackToSystem() {
        #expect(AppearanceTheme.resolved(rawValue: nil) == .system)
        #expect(AppearanceTheme.resolved(rawValue: "") == .system)
        #expect(AppearanceTheme.resolved(rawValue: "amoled") == .system)
        #expect(AppearanceTheme.resolved(rawValue: "TrueBlack") == .system)
    }

    @Test func everyThemeRoundTripsThroughUserDefaults() throws {
        let suiteName = "appearance-theme-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        for theme in AppearanceTheme.allCases {
            defaults.set(theme.rawValue, forKey: AppearanceTheme.storageKey)
            let stored = defaults.string(forKey: AppearanceTheme.storageKey)
            #expect(AppearanceTheme.resolved(rawValue: stored) == theme)
        }
    }

    @Test func preferredColorSchemeTreatsTrueBlackAsDark() {
        #expect(AppearanceTheme.system.preferredColorScheme == nil)
        #expect(AppearanceTheme.light.preferredColorScheme == .light)
        #expect(AppearanceTheme.dark.preferredColorScheme == .dark)
        #expect(AppearanceTheme.trueBlack.preferredColorScheme == .dark)
    }

    @Test func userInterfaceStyleTreatsTrueBlackAsDark() {
        #expect(AppearanceTheme.system.userInterfaceStyle == .unspecified)
        #expect(AppearanceTheme.light.userInterfaceStyle == .light)
        #expect(AppearanceTheme.dark.userInterfaceStyle == .dark)
        #expect(AppearanceTheme.trueBlack.userInterfaceStyle == .dark)
    }

    @Test func onlyTrueBlackRepaintsScaffoldSurfaces() {
        for theme in AppearanceTheme.allCases {
            #expect(theme.usesTrueBlackSurfaces == (theme == .trueBlack))
        }
    }

    @Test func pickerOffersTrueBlackAfterDark() {
        #expect(AppearanceTheme.allCases == [.system, .light, .dark, .trueBlack])
    }

    @Test func appearanceSelectionResolvesTrueBlackFromStoredRawValue() {
        let selection = AppAppearanceSelection(themeRawValue: "trueBlack", languageRawValue: nil)
        #expect(selection.theme == .trueBlack)
        #expect(selection.preferredColorScheme == .dark)
    }
}
