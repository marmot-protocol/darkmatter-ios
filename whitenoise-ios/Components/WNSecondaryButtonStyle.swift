import SwiftUI

struct WNSecondaryButtonStyle: ButtonStyle {
    nonisolated enum Surface: Equatable {
        case lifted
        case translucent
    }

    nonisolated enum Metrics {
        static let horizontalPadding: CGFloat = 20
        static let shadowRadius: CGFloat = 6
        static let shadowOffsetY: CGFloat = 2
        static let pressFade = 0.7

        static func verticalPadding(for controlSize: ControlSize) -> CGFloat {
            controlSize == .extraLarge ? 15 : 10
        }

        static func surface(for colorScheme: ColorScheme) -> Surface {
            colorScheme == .dark ? .translucent : .lifted
        }

        static func fill(for surface: Surface) -> AnyShapeStyle {
            switch surface {
            case .lifted: AnyShapeStyle(.background)
            case .translucent: AnyShapeStyle(.quaternary)
            }
        }

        static func shadowOpacity(for colorScheme: ColorScheme) -> Double {
            colorScheme == .dark ? 0 : 0.12
        }

        static func labelColor(isEnabled: Bool) -> Color {
            isEnabled ? .primary : .secondary
        }

        static func opacity(isPressed: Bool) -> Double {
            isPressed ? pressFade : 1
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        WNSecondaryButtonLabel(configuration: configuration)
    }
}

extension ButtonStyle where Self == WNSecondaryButtonStyle {
    static var wnSecondary: Self { WNSecondaryButtonStyle() }
}

private struct WNSecondaryButtonLabel: View {
    private typealias Metrics = WNSecondaryButtonStyle.Metrics

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled

    let configuration: WNSecondaryButtonStyle.Configuration

    var body: some View {
        configuration.label
            .foregroundStyle(Metrics.labelColor(isEnabled: isEnabled))
            .padding(.horizontal, Metrics.horizontalPadding)
            .padding(.vertical, Metrics.verticalPadding(for: controlSize))
            .background {
                Capsule()
                    .fill(Metrics.fill(for: Metrics.surface(for: colorScheme)))
                    .shadow(
                        color: .black.opacity(Metrics.shadowOpacity(for: colorScheme)),
                        radius: Metrics.shadowRadius,
                        y: Metrics.shadowOffsetY
                    )
            }
            .contentShape(.capsule)
            .opacity(Metrics.opacity(isPressed: configuration.isPressed))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview("WNSecondaryButtonStyle — Light") {
    VStack(spacing: 24) {
        Button("Sign In") {}
            .buttonStyle(.wnSecondary)

        Button("Add Photo") {}
            .buttonStyle(.wnSecondary)
            .disabled(true)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
}

#Preview("WNSecondaryButtonStyle — Dark") {
    VStack(spacing: 24) {
        Button("Sign In") {}
            .buttonStyle(.wnSecondary)

        Button("Add Photo") {}
            .buttonStyle(.wnSecondary)
            .disabled(true)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.background)
    .preferredColorScheme(.dark)
}
