import SwiftUI

struct WNButton: View {
    nonisolated enum Emphasis: Equatable {
        case primary
        case secondary
    }

    nonisolated enum Metrics {
        static let fallbackLabelMinHeight: CGFloat = 44

        static func accent(for colorScheme: ColorScheme) -> Color {
            colorScheme == .dark ? .white : .black
        }

        static func contentColor(
            emphasis: Emphasis,
            colorScheme: ColorScheme,
            isEnabled: Bool
        ) -> Color {
            guard isEnabled else { return .secondary }

            switch emphasis {
            case .primary:
                return colorScheme == .dark ? .black : .white
            case .secondary:
                return accent(for: colorScheme)
            }
        }
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    let title: LocalizedStringKey
    var systemImage: String?
    var emphasis = Emphasis.primary
    var isLoading = false
    let action: () -> Void

    var body: some View {
        let contentColor = Metrics.contentColor(
            emphasis: emphasis,
            colorScheme: colorScheme,
            isEnabled: isEnabled
        )

        return Button(action: action) {
            ZStack {
                WNButtonTitle(title: title, systemImage: systemImage)
                    .opacity(isLoading ? 0 : 1)

                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(contentColor)
                        .transition(.opacity)
                }
            }
            .foregroundStyle(contentColor)
            .animation(.default, value: isLoading)
            .wnButtonLabelSizing()
        }
        .wnButtonStyle(emphasis)
        .wnButtonChrome()
        .controlSize(.extraLarge)
        .wnButtonSizing()
        .allowsHitTesting(!isLoading)
    }
}

private struct WNButtonTitle: View {
    let title: LocalizedStringKey
    let systemImage: String?

    var body: some View {
        if let systemImage {
            Label(title, systemImage: systemImage)
        } else {
            Text(title)
        }
    }
}

private struct WNButtonChrome: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .buttonBorderShape(.capsule)
            .tint(WNButton.Metrics.accent(for: colorScheme))
    }
}

extension View {
    func wnButtonChrome() -> some View {
        modifier(WNButtonChrome())
    }

    func wnAvatarActionButtonStyle() -> some View {
        wnSecondaryButtonStyle()
            .wnButtonChrome()
    }

    @ViewBuilder
    func wnButtonStyle(_ emphasis: WNButton.Emphasis) -> some View {
        switch emphasis {
        case .primary:
            wnPrimaryButtonStyle()
        case .secondary:
            wnSecondaryButtonStyle()
        }
    }

    @ViewBuilder
    func wnPrimaryButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func wnSecondaryButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func wnButtonSizing() -> some View {
        if #available(iOS 26.0, *) {
            buttonSizing(.flexible)
        } else {
            self
        }
    }

    @ViewBuilder
    func wnButtonLabelSizing() -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            frame(maxWidth: .infinity, minHeight: WNButton.Metrics.fallbackLabelMinHeight)
        }
    }
}

#Preview("WNButton — Light") {
    VStack {
        WNButton(title: "Sign In", emphasis: .secondary) {}
        WNButton(title: "Sign Up") {}
        WNButton(title: "Add Profile", systemImage: "person.crop.circle.badge.plus") {}
        WNButton(title: "Signing Up…", isLoading: true) {}
        WNButton(title: "Sign Up") {}
            .disabled(true)
    }
    .safeAreaPadding(.horizontal)
}

#Preview("WNButton — Dark") {
    VStack {
        WNButton(title: "Sign In", emphasis: .secondary) {}
        WNButton(title: "Sign Up") {}
        WNButton(title: "Signing Up…", isLoading: true) {}
    }
    .safeAreaPadding(.horizontal)
    .preferredColorScheme(.dark)
}

#Preview("WN avatar action — Light") {
    VStack(spacing: 24) {
        Button("Add Photo") {}
            .wnAvatarActionButtonStyle()

        Menu("Change Photo") {
            Button("Choose from Photos") {}
        }
        .wnAvatarActionButtonStyle()

        Button("Add Photo") {}
            .wnAvatarActionButtonStyle()
            .disabled(true)
    }
}

#Preview("WN avatar action — Dark") {
    VStack(spacing: 24) {
        Button("Add Photo") {}
            .wnAvatarActionButtonStyle()

        Menu("Change Photo") {
            Button("Choose from Photos") {}
        }
        .wnAvatarActionButtonStyle()
    }
    .preferredColorScheme(.dark)
}
