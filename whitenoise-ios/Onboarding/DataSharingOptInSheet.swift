import SwiftUI

/// The one-time data-sharing choice, offered over the chat list the first time an
/// identity gets there.
///
/// Ported from `wn-ios-prototype`'s diagnostics prompt, which puts the ask in one
/// compact card rather than a step inside sign-up: the introduction above the
/// switches, both switches directly reachable with no further navigation, the
/// privacy detail below them, and a single dismissal because the choices apply
/// the moment they are flipped. There is no Save and no Cancel — leaving both off
/// is a valid answer, and closing only dismisses what is already written.
///
/// Laid out in a plain stack rather than the prototype's `Form`. A `Form` is a
/// `List`, and inside a `presentationDetents` sheet a list's scroll gesture
/// competes with the sheet's interactive dismiss; `UISwitch` tracks pans, so a
/// touch meant for a switch can be claimed by whichever recognizer wins. Nothing
/// here scrolls, so there is no competing recognizer. `scrollDisabled` would not
/// do: it stops the scrolling, not the recognizer.
///
/// The switches are `DataSharingToggleRows`, the same rows Privacy & Security
/// shows — the screen this sheet's copy points at — so it offers exactly the
/// settings it claims to and cannot drift from them. What the sheet itself owns
/// is the copy explaining the ask.
struct DataSharingOptInSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var model = PrivacySecuritySettingsViewModel()

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                DataSharingOptInIntroduction()

                DataSharingToggleCard(model: model)

                Text("Telemetry never includes messages, media, contacts, profile details, or keys. Audit logs obscure identifiers and are sent securely to White Noise for troubleshooting.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                // Toasts host at the root, below this sheet, so a refused write or
                // a failed settings read would otherwise leave the switches inert
                // with no explanation.
                if let message = failureMessage {
                    DataSharingOptInFailureLabel(message: message)
                }

                Spacer(minLength: 0)
            }
            .safeAreaPadding(.horizontal)
            .padding(.top)
            .localizedNavigationTitle("Help Improve White Noise")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .labelStyle(.iconOnly)
                        // The app's asset-catalog AccentColor is empty, so an
                        // untinted control falls back to the system blue. The
                        // prototype's chrome is monochrome.
                        .tint(.primary)
                }
            }
            .task(id: appState.activeAccountRef) { await model.reload(using: appState) }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
    }

    private var failureMessage: String? {
        model.errorMessage ?? model.telemetryErrorMessage ?? model.auditErrorMessage
    }
}

private struct DataSharingOptInIntroduction: View {
    var body: some View {
        Text("Help us make messaging without a central point of control more reliable. Both of these are optional, and you can change them in Settings at any time.")
            .font(.body)
            .foregroundStyle(.primary)
    }
}

/// The two switches as a grouped card. The prototype groups them inside a
/// `Form` section; this rebuilds that look without a list, reusing the metrics
/// the profile screens already use for hand-built grouped cards so the surfaces
/// stay consistent.
private struct DataSharingToggleCard: View {
    let model: PrivacySecuritySettingsViewModel

    var body: some View {
        VStack(spacing: 12) {
            DataSharingToggleRows(model: model)
        }
        .padding(16)
        .background(
            Color(uiColor: .secondarySystemGroupedBackground),
            in: .rect(cornerRadius: 12)
        )
    }
}

private struct DataSharingOptInFailureLabel: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.red)
            .font(.callout)
    }
}

#Preview("Data sharing opt-in") {
    DataSharingOptInSheet()
        .environment(AppState())
}
