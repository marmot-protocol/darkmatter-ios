import SwiftUI
import UIKit

struct AppAppearanceSelection: Equatable {
    let theme: AppearanceTheme
    let language: AppLanguage

    init(themeRawValue: String?, languageRawValue: String?) {
        self.theme = AppearanceTheme.resolved(rawValue: themeRawValue)
        self.language = AppLanguage.resolved(rawValue: languageRawValue)
    }

    var locale: Locale {
        language.locale ?? .autoupdatingCurrent
    }

    var preferredColorScheme: ColorScheme? {
        theme.preferredColorScheme
    }
}

private struct AppAppearanceModifier: ViewModifier {
    @AppStorage(AppearanceTheme.storageKey) private var themeRawValue = AppearanceTheme.system.rawValue
    @State private var languageRawValue = AppLanguage.currentRawValue

    private var selection: AppAppearanceSelection {
        AppAppearanceSelection(themeRawValue: themeRawValue, languageRawValue: languageRawValue)
    }

    func body(content: Content) -> some View {
        content
            .environment(\.locale, selection.locale)
            .onAppear {
                languageRawValue = AppLanguage.currentRawValue
                AppAppearanceRuntime.apply(theme: selection.theme)
            }
            .onReceive(NotificationCenter.default.publisher(for: AppLanguage.didChangeNotification)) { _ in
                languageRawValue = AppLanguage.currentRawValue
            }
            .onChange(of: selection.theme) { _, theme in
                AppAppearanceRuntime.apply(theme: theme)
            }
    }
}

@MainActor
private enum AppAppearanceRuntime {
    static func apply(theme: AppearanceTheme) {
        let style = theme.userInterfaceStyle
        UIView.appearance().overrideUserInterfaceStyle = style

        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
                apply(style: style, to: window.rootViewController)
            }
        }
    }

    private static func apply(style: UIUserInterfaceStyle, to viewController: UIViewController?) {
        guard let viewController else { return }

        viewController.overrideUserInterfaceStyle = style
        viewController.setNeedsStatusBarAppearanceUpdate()

        for child in viewController.children {
            apply(style: style, to: child)
        }

        apply(style: style, to: viewController.presentedViewController)
    }
}

private struct TrueBlackScaffoldBackgroundModifier: ViewModifier {
    @AppStorage(AppearanceTheme.storageKey) private var themeRawValue = AppearanceTheme.system.rawValue

    private var isActive: Bool {
        AppearanceTheme.resolved(rawValue: themeRawValue).usesTrueBlackSurfaces
    }

    func body(content: Content) -> some View {
        // Branch on modifier values, not view structure, so switching themes
        // keeps scroll position and other subtree state.
        content
            .scrollContentBackground(isActive ? .hidden : .automatic)
            .background {
                if isActive {
                    Color.black.ignoresSafeArea()
                }
            }
    }
}

extension View {
    func appAppearance() -> some View {
        modifier(AppAppearanceModifier())
    }

    /// Paints this scaffold surface pure black while the true black theme is
    /// active. Apply to top-level scroll containers (chat list, conversation
    /// timeline, settings forms), not to individual components.
    func trueBlackScaffoldBackground() -> some View {
        modifier(TrueBlackScaffoldBackgroundModifier())
    }
}
