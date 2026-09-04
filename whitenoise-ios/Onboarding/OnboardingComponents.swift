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

