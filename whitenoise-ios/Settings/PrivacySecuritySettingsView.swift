import LocalAuthentication
import SwiftUI

struct PrivacySecuritySettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var model = PrivacySecuritySettingsViewModel()
    @State private var appLockCapability = AppLockCapability(available: false, biometryType: .none)

    var body: some View {
        @Bindable var model = model
        return Form {
            Section {
                Toggle(isOn: Binding(
                    get: { appState.appLock.isEnabled },
                    set: { enabled in Task { await appState.appLock.setEnabled(enabled) } }
                )) {
                    Label(appLockToggleTitle, systemImage: appLockToggleIcon)
                }
                .disabled(!appLockCapability.available)

                if appState.appLock.isEnabled {
                    Picker(selection: Binding(
                        get: { appState.appLock.gracePeriod },
                        set: { appState.appLock.gracePeriod = $0 }
                    )) {
                        ForEach(AppLockGracePeriod.allCases, id: \.self) { period in
                            Text(period.displayName).tag(period)
                        }
                    } label: {
                        Label("Auto-lock", systemImage: "clock")
                    }
                }
            } header: {
                Text("App Lock")
            } footer: {
                if appLockCapability.available {
                    Text("Hides the app's content in the app switcher and requires unlocking when you return.")
                } else {
                    Text("To use App Lock, set a passcode on this device.")
                }
            }

            Section {
                Toggle(isOn: Binding(
                    get: { appState.blockScreenshots },
                    set: { appState.blockScreenshots = $0 }
                )) {
                    Label("Block screenshots", systemImage: "camera.viewfinder")
                }
            } header: {
                Text("Screen Capture")
            } footer: {
                Text("Screenshots and screen recordings of the app show a blank screen. The app's preview in the app switcher is hidden too.")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { model.telemetrySettings?.exportEnabled ?? false },
                    set: { enabled in Task { await model.setTelemetryEnabled(enabled, using: appState) } }
                )) {
                    HStack {
                        Label("Anonymous Telemetry", systemImage: "chart.line.uptrend.xyaxis")
                        Spacer()
                        if model.telemetrySaving {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(model.telemetryToggleDisabled)
            } header: {
                Text("Telemetry")
            } footer: {
                Text(telemetryFooter)
            }

            Section {
                Toggle(isOn: Binding(
                    get: { appState.developerMode },
                    set: { appState.developerMode = $0 }
                )) {
                    Label("Developer mode", systemImage: "apple.terminal")
                }

                if appState.developerMode {
                    Toggle(isOn: Binding(
                        get: { appState.streamingDebugMode },
                        set: { appState.streamingDebugMode = $0 }
                    )) {
                        Label("Streaming debug", systemImage: "waveform.path.ecg")
                    }

                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Open Diagnostics", systemImage: "stethoscope")
                    }

                }
            } header: {
                Text("Developer")
            } footer: {
                Text("Adds debugging tools, including MLS group internals and diagnostics. Streaming debug shows every agent-stream MLS event and live QUIC update in the conversation timeline. The diagnostics console can log message text and account activity on this device.")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { model.auditSettings?.enabled ?? false },
                    set: { enabled in Task { await model.setAuditEnabled(enabled, using: appState) } }
                )) {
                    HStack {
                        Label("Audit Logging", systemImage: "doc.text.magnifyingglass")
                        Spacer()
                        if model.auditSaving {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                .disabled(model.auditToggleDisabled)

                if model.auditSettings?.enabled == true {
                    Toggle(isOn: Binding(
                        get: { model.auditSettings?.includesSensitiveData ?? false },
                        set: { enabled in
                            Task {
                                await model.setAuditSensitiveDataEnabled(
                                    enabled,
                                    using: appState
                                )
                            }
                        }
                    )) {
                        Label("Include Sensitive Data", systemImage: "exclamationmark.shield.fill")
                    }
                    .disabled(model.auditToggleDisabled)
                }
            } header: {
                Text("Audit Logging")
            } footer: {
                if model.auditSettings?.enabled == true {
                    Text("By default, identifiers are obscured and message content is excluded. Include Sensitive Data adds decrypted message content and full identifiers for forensic review, but never private keys or authentication tokens. Changes apply immediately.")
                } else {
                    Text("Writes local audit JSONL files for forensic review using obscured identifiers and no message content. Changes apply immediately.")
                }
            }

            Section {
                if model.filesLoading && model.auditFileRows.isEmpty {
                    HStack {
                        Spacer()
                        ProgressView("Loading audit logs")
                        Spacer()
                    }
                    .padding(.vertical, 16)
                } else if model.auditFileRows.isEmpty {
                    Text("No audit logs on this device.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.auditFileRows) { row in
                        auditFileRow(row)
                    }

                    Button(role: .destructive) {
                        model.showDeleteAuditLogsConfirmation = true
                    } label: {
                        Label("Delete All Audit Logs", systemImage: "trash")
                    }
                    .disabled(model.auditDeleteDisabled)
                }

                if model.auditDeleting {
                    ProgressView("Deleting audit logs")
                }

                if let auditErrorMessage = model.auditErrorMessage {
                    inlineLoadFailure(auditErrorMessage) {
                        Task { await model.reloadAuditFiles(using: appState) }
                    }
                }
            } header: {
                Text("Audit Log Files")
            } footer: {
                if !model.auditFileRows.isEmpty {
                    Text("Deletes every local audit JSONL file on this device. Live recorders rotate to fresh files when audit logging is still on.")
                }
            }

            if let errorMessage = model.errorMessage {
                Section {
                    inlineLoadFailure(errorMessage) {
                        Task { await model.reload(using: appState) }
                    }
                }
            }
        }
        .localizedNavigationTitle("Privacy & Security")
        .navigationBarTitleDisplayMode(.inline)
        .task { appLockCapability = AppLockCapability.current() }
        .task(id: appState.activeAccountRef) { await model.reload(using: appState) }
        .refreshable { await model.reload(using: appState) }
        .alert(
            "Delete all audit logs?",
            isPresented: $model.showDeleteAuditLogsConfirmation
        ) {
            Button("Delete All Audit Logs", role: .destructive) {
                Task { await model.deleteAllAuditLogs(using: appState) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every local audit JSONL file on this device.")
        }
    }

    private var telemetryFooter: String {
        "Anonymous telemetry helps improve reliability and performance."
    }

    private func inlineLoadFailure(_: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Couldn't load this screen", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout)
            Button("Retry", action: retry)
        }
    }

    private var appLockToggleTitle: String {
        switch appLockCapability.biometryType {
        case .faceID: L10n.string("Require Face ID")
        case .touchID: L10n.string("Require Touch ID")
        case .opticID: L10n.string("Require Optic ID")
        default: L10n.string("Require passcode")
        }
    }

    private var appLockToggleIcon: String {
        switch appLockCapability.biometryType {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        default: "lock.fill"
        }
    }

    @ViewBuilder
    private func auditFileRow(_ row: AuditFileRow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(row.fileName)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Text(row.detailText)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(row.path)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }
}
