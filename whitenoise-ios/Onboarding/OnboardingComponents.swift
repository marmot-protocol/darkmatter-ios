import SwiftUI
import UIKit

enum OnboardingSheetContent: Equatable {
    case welcome
    case signIn
    case signUp

    var prefersCompactHeight: Bool {
        self == .signIn
    }
}

struct OnboardingPrimaryActionLabel: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    let title: LocalizedStringKey
    let isLoading: Bool
    var isActionEnabled = true

    private var contentColor: Color {
        guard isEnabled && isActionEnabled else {
            return Color(uiColor: .tertiaryLabel)
        }
        return colorScheme == .dark ? .black : .white
    }

    var body: some View {
        ZStack {
            Text(title)
                .foregroundStyle(contentColor)
                .opacity(isLoading ? 0 : 1)

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(contentColor)
                    .transition(.opacity)
            }
        }
        .animation(.default, value: isLoading)
    }
}

struct OnboardingAvatarPreview: View {
    @Environment(\.colorScheme) private var colorScheme

    let name: String
    let image: UIImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Circle()
                    .fill(colorScheme == .dark ? Color.white : Color.black)

                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    Text(initial)
                        .font(.largeTitle.weight(.semibold))
                        .foregroundStyle(colorScheme == .dark ? Color.black : Color.white)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(.circle)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("Profile avatar preview"))
    }

    private var initial: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .first
            .map { String($0).uppercased() }
            ?? "?"
    }
}

extension View {
    @ViewBuilder
    func onboardingPrimaryButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func onboardingSecondaryButtonStyle() -> some View {
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func onboardingFlexibleButtonSizing() -> some View {
        if #available(iOS 26.0, *) {
            buttonSizing(.flexible)
        } else {
            frame(maxWidth: .infinity)
        }
    }
}
