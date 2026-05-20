import SwiftUI

/// Transient banner shown at the top of the screen. Used for non-fatal
/// success/failure messages that don't warrant a sheet or a full error
/// state on the current screen.
struct Toast: Identifiable, Equatable {
    enum Style: Equatable {
        case success
        case warning
        case error
    }

    let id = UUID()
    let title: String
    let message: String?
    let style: Style
    let duration: TimeInterval

    static func success(_ title: String, message: String? = nil, duration: TimeInterval = 2.5) -> Toast {
        Toast(title: title, message: message, style: .success, duration: duration)
    }

    static func warning(_ title: String, message: String? = nil, duration: TimeInterval = 3.0) -> Toast {
        Toast(title: title, message: message, style: .warning, duration: duration)
    }

    static func error(_ title: String, message: String? = nil, duration: TimeInterval = 3.5) -> Toast {
        Toast(title: title, message: message, style: .error, duration: duration)
    }
}

/// Top-of-screen overlay host. Attach to the root view; views below read
/// `AppState.activeToast` and call `appState.present(_:)` / `appState.dismissToast()`.
struct ToastHost: ViewModifier {
    @Environment(AppState.self) private var appState

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast = appState.activeToast {
                    ToastView(toast: toast)
                        .padding(.horizontal, 16)
                        .padding(.top, 4)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .id(toast.id)
                }
            }
            .animation(.smooth(duration: 0.25), value: appState.activeToast)
    }
}

private struct ToastView: View {
    let toast: Toast

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)

            VStack(alignment: .leading, spacing: 2) {
                Text(toast.title)
                    .font(.callout.weight(.semibold))
                if let message = toast.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.thinMaterial, in: .rect(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(tint.opacity(0.3), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.08), radius: 10, x: 0, y: 4)
    }

    private var icon: String {
        switch toast.style {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch toast.style {
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

extension View {
    func toastHost() -> some View {
        modifier(ToastHost())
    }
}
