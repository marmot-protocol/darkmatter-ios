import LocalAuthentication
import SwiftUI

struct PrivacySecuritySettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var appLockCapability = AppLockCapability(available: false, biometryType: .none)
    @State private var dataSharing = PrivacySecuritySettingsViewModel()

    var body: some View {
        Form {
            Section {
                Toggle("Hide Screen in App Switcher", isOn: Binding(
                    get: { appState.blockScreenshots },
                    set: { appState.blockScreenshots = $0 }
                ))
                .wnToggleTint()
            } header: {
                Text("App Security")
            } footer: {
                Text("Hides your conversations and profile details in the app switcher. Screenshots and screen recordings also show a blank screen.")
            }

            Section {
                Toggle(appLockToggleTitle, isOn: Binding(
                    get: { appState.appLock.isEnabled },
                    set: { enabled in Task { await appState.appLock.setEnabled(enabled) } }
                ))
                .wnToggleTint()
                .disabled(!appLockCapability.available)

                if appState.appLock.isEnabled && appLockCapability.available {
                    Picker("Auto-Lock", selection: Binding(
                        get: { appState.appLock.gracePeriod },
                        set: { appState.appLock.gracePeriod = $0 }
                    )) {
                        ForEach(AppLockGracePeriod.allCases, id: \.self) { period in
                            Text(period.displayName).tag(period)
                        }
                    }
                }
            } footer: {
                Text(appLockFooter)
            }

            // The one-time data-sharing offer promises both switches can be
            // changed "in Settings at any time"; this is where it points.
            Section {
                AnonymousTelemetryToggleRow(model: dataSharing)
            } header: {
                Text("Data Sharing")
            } footer: {
                Text("Shares anonymous reliability and performance data. It doesn’t include messages or profile keys.")
            }

            Section {
                AuditLoggingToggleRow(model: dataSharing)
            } footer: {
                Text("Stores technical activity locally for troubleshooting.")
            }

            // A refused save springs the switch back, and a failed settings read
            // renders both switches from nil (so both disable). Without this,
            // either looks like the screen is simply broken.
            if let message = dataSharing.errorMessage
                ?? dataSharing.telemetryErrorMessage
                ?? dataSharing.auditErrorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
        .localizedNavigationTitle("Privacy & Security")
        .navigationBarTitleDisplayMode(.inline)
        .task { appLockCapability = AppLockCapability.current() }
        .task(id: appState.activeAccountRef) { await dataSharing.reload(using: appState) }
    }

    private var appLockToggleTitle: String {
        switch appLockCapability.biometryType {
        case .faceID: L10n.string("Require Face ID")
        case .touchID: L10n.string("Require Touch ID")
        case .opticID: L10n.string("Require Optic ID")
        default: L10n.string("Require passcode")
        }
    }

    private var appLockFooter: String {
        guard appLockCapability.available else {
            return L10n.string("Set an iPhone passcode to lock White Noise.")
        }
        return L10n.string("Locks White Noise when you leave. Your iPhone passcode can be used if biometric authentication isn't available.")
    }
}
