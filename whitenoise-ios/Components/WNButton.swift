import SwiftUI

struct WNButton: View {
    nonisolated enum Emphasis: Equatable {
        case primary
        case secondary
    }

    /// `large` is the full-width call to action at the bottom of a screen.
    /// `compact` hugs its label so the same chrome fits a toolbar or a row.
    nonisolated enum Size: Equatable {
        case large
        case compact
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

        static func controlSize(for size: Size) -> ControlSize {
            size == .large ? .extraLarge : .regular
        }

        /// Only the large size claims the full width; a compact button in a
        /// toolbar has to stay as wide as its title.
        static func stretches(_ size: Size) -> Bool {
            size == .large
        }
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    let title: LocalizedStringKey
    var systemImage: String?
    var emphasis = Emphasis.primary
    var size = Size.large
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
            .wnButtonLabelSizing(size)
        }
        .wnButtonStyle(emphasis)
        .wnButtonChrome()
        .controlSize(Metrics.controlSize(for: size))
        .wnButtonSizing(size)
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

    let borderShape: ButtonBorderShape

    func body(content: Content) -> some View {
        content
            .buttonBorderShape(borderShape)
            .tint(WNButton.Metrics.accent(for: colorScheme))
    }
}

extension View {
    func wnButtonChrome(_ borderShape: ButtonBorderShape = .capsule) -> some View {
        modifier(WNButtonChrome(borderShape: borderShape))
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
    func wnSecondaryButtonStyle(
        _ shape: WNSecondaryButtonStyle.Shape = .capsule
    ) -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(WNSecondaryButtonStyle(shape: shape))
        }
    }

    @ViewBuilder
    func wnButtonSizing(_ size: WNButton.Size = .large) -> some View {
        if #available(iOS 26.0, *), WNButton.Metrics.stretches(size) {
            buttonSizing(.flexible)
        } else {
            self
        }
    }

    @ViewBuilder
    func wnButtonLabelSizing(_ size: WNButton.Size = .large) -> some View {
        if #available(iOS 26.0, *) {
            self
        } else if WNButton.Metrics.stretches(size) {
            frame(maxWidth: .infinity, minHeight: WNButton.Metrics.fallbackLabelMinHeight)
        } else {
            self
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

#Preview("WNButton — Compact") {
    VStack(spacing: 24) {
        WNButton(title: "Edit", emphasis: .secondary, size: .compact) {}
        WNButton(title: "Done", size: .compact) {}
        WNButton(title: "Publishing…", size: .compact, isLoading: true) {}
        WNButton(title: "Edit", emphasis: .secondary, size: .compact) {}
            .disabled(true)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
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
