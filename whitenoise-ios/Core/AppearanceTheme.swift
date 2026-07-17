import SwiftUI
import UIKit

enum AppearanceTheme: String, CaseIterable, Identifiable {
    case system
    case light
    case dark
    case trueBlack

    static let storageKey = "appearance.theme"

    static func resolved(rawValue: String?) -> AppearanceTheme {
        rawValue.flatMap(AppearanceTheme.init(rawValue:)) ?? .system
    }

    var id: String { rawValue }

    var preferredColorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark, .trueBlack:
            .dark
        }
    }

    var userInterfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system:
            .unspecified
        case .light:
            .light
        case .dark, .trueBlack:
            .dark
        }
    }

    /// True black behaves as dark mode but repaints the main scaffold surfaces
    /// pure black for OLED displays — component colors keep dark-mode semantics.
    var usesTrueBlackSurfaces: Bool {
        self == .trueBlack
    }

    var displayName: LocalizedStringKey {
        switch self {
        case .system:
            "System"
        case .light:
            "Light"
        case .dark:
            "Dark"
        case .trueBlack:
            "True Black"
        }
    }
}
