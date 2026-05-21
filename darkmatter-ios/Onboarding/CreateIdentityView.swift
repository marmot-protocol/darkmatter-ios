import SwiftUI

/// Generate a brand-new Nostr identity. The keypair is created and stored in
/// the iOS Keychain inside marmot-app; we never see the nsec in Swift.
///
/// On success the parent routes automatically: during onboarding the app
/// advances to the main UI; when adding an account, the Accounts sheet
/// dismisses back to the accounts list. There's no intermediate "created"
/// screen.
struct CreateIdentityView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                Text("Generates a fresh Nostr identity and stores the secret key in your device's secure enclave.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    Task { await runCreate() }
                } label: {
                    HStack {
                        if isCreating {
                            ProgressView().controlSize(.small)
                        }
                        Text(isCreating ? "Creating…" : "Generate Identity")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 2)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isCreating)
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
        .navigationTitle("New Identity")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isCreating)
    }

    @MainActor
    private func runCreate() async {
        isCreating = true
        error = nil
        do {
            try await appState.createIdentity()
            Haptics.success()
            // Parent handles navigation (sheet dismiss / onboarding advance).
            dismiss()
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
            appState.present(.error("Identity creation failed", message: error.localizedDescription))
        }
        isCreating = false
    }
}
