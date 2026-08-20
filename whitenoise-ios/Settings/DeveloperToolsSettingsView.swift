import SwiftUI
import MarmotKit

struct DeveloperToolsSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var model = PrivacySecuritySettingsViewModel()

    var body: some View {
        @Bindable var model = model
        return Form {
            Section {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("For development and testing only")
                        Text("These tools can expose technical information and change how the app behaves.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Toggle("Developer Tools", isOn: Binding(
                    get: { appState.developerMode },
                    set: { appState.developerMode = $0 }
                ))
            } footer: {
                Text("Enable technical tools for this profile.")
            }

            if appState.developerMode {
                Section {
                    Toggle("Debug Mode", isOn: Binding(
                        get: { appState.streamingDebugMode },
                        set: { appState.streamingDebugMode = $0 }
                    ))

                    NavigationLink {
                        DiagnosticsView()
                    } label: {
                        Label("Diagnostics", systemImage: "stethoscope")
                    }
                } header: {
                    Text("Debugging")
                } footer: {
                    Text("Debug Mode adds technical conversation details intended for development and testing.")
                }

                Section {
                    NavigationLink {
                        KeyPackagesView()
                    } label: {
                        Label("Key Packages", systemImage: "shippingbox")
                    }
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { model.telemetrySettings?.exportEnabled ?? false },
                        set: { enabled in Task { await model.setTelemetryEnabled(enabled, using: appState) } }
                    )) {
                        HStack {
                            Text("Anonymous Telemetry")
                            Spacer()
                            if model.telemetrySaving { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(model.telemetryToggleDisabled)
                } header: {
                    Text("Telemetry")
                } footer: {
                    Text("Shares anonymous reliability and performance data. It doesn’t include messages or profile keys.")
                }

                Section {
                    Toggle(isOn: Binding(
                        get: { model.auditSettings?.enabled ?? false },
                        set: { enabled in Task { await model.setAuditEnabled(enabled, using: appState) } }
                    )) {
                        HStack {
                            Text("Audit Logging")
                            Spacer()
                            if model.auditSaving { ProgressView().controlSize(.small) }
                        }
                    }
                    .disabled(model.auditToggleDisabled)

                    if model.auditSettings?.enabled == true {
                        if model.filesLoading && model.auditFileRows.isEmpty {
                            ProgressView("Loading audit logs")
                        } else {
                            ForEach(model.auditFileRows) { row in
                                auditFileRow(row)
                            }
                        }

                        Button("Clear Audit Logs", role: .destructive) {
                            model.showDeleteAuditLogsConfirmation = true
                        }
                        .disabled(model.auditDeleteDisabled || model.auditFileRows.isEmpty)
                    }
                } header: {
                    Text("Audit Logging")
                } footer: {
                    Text("Stores technical activity locally for troubleshooting.")
                }
            }

            if let errorMessage = model.errorMessage ?? model.auditErrorMessage {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.callout)
                        Button("Retry") {
                            Task { await model.reload(using: appState) }
                        }
                    }
                }
            }

            Section("About") {
                LabeledContent("Version", value: appVersion)
                LabeledContent("Built on") {
                    Text(marmotBuildLabel)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
        }
        .localizedNavigationTitle("Developer Tools")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: appState.activeAccountRef) { await model.reload(using: appState) }
        .refreshable { await model.reload(using: appState) }
        .alert("Clear all audit logs?", isPresented: $model.showDeleteAuditLogsConfirmation) {
            Button("Clear Logs", role: .destructive) {
                Task { await model.deleteAllAuditLogs(using: appState) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes every local audit JSONL file on this device.")
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var marmotBuildLabel: String {
        MarmotKitBuildLabel.text(tag: MarmotKitVersion.mdkTag, sha: MarmotKitVersion.mdkSHA)
    }

    private func auditFileRow(_ row: AuditFileRow) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(row.fileName)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            Text(row.detailText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
