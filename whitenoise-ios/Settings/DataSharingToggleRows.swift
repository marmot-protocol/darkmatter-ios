import SwiftUI

/// Wording follows `wn-ios-prototype` ("Share Anonymous Analytics" / "Share
/// Diagnostic Logs") rather than the engine's own terms, so the two settings read
/// as choices about sharing rather than as internal subsystem names.
///
/// The anonymous-telemetry choice, as a row shared by Privacy & Security,
/// Developer Tools, and the one-time data-sharing sheet.
///
/// Every surface reads and writes through the same `PrivacySecuritySettingsViewModel`,
/// which moves the switch optimistically and rolls it back if Marmot refuses.
/// Duplicating the binding would let one surface drift into writing the
/// preference some other way — an optimistic move without the rollback, say.
struct AnonymousTelemetryToggleRow: View {
    @Environment(AppState.self) private var appState
    let model: PrivacySecuritySettingsViewModel

    var body: some View {
        Toggle(isOn: Binding(
            get: { model.telemetrySettings?.exportEnabled ?? false },
            set: { enabled in Task { await model.setTelemetryEnabled(enabled, using: appState) } }
        )) {
            DataSharingToggleLabel(title: "Share Anonymous Analytics", isSaving: model.telemetrySaving)
        }
        .wnToggleTint()
        .disabled(model.telemetryToggleDisabled)
    }
}

/// The audit-logging choice, as a row shared by Privacy & Security, Developer
/// Tools, and the one-time data-sharing sheet. See `AnonymousTelemetryToggleRow`
/// for why it is shared.
struct AuditLoggingToggleRow: View {
    @Environment(AppState.self) private var appState
    let model: PrivacySecuritySettingsViewModel

    var body: some View {
        Toggle(isOn: Binding(
            get: { model.auditSettings?.enabled ?? false },
            set: { enabled in Task { await model.setAuditEnabled(enabled, using: appState) } }
        )) {
            DataSharingToggleLabel(title: "Share Diagnostic Logs", isSaving: model.auditSaving)
        }
        .wnToggleTint()
        .disabled(model.auditToggleDisabled)
    }
}

/// Both choices in reading order, for the sheet, which asks them together in one
/// card. The settings screens take them separately so each can carry the footer
/// that explains it.
struct DataSharingToggleRows: View {
    let model: PrivacySecuritySettingsViewModel

    var body: some View {
        AnonymousTelemetryToggleRow(model: model)
        AuditLoggingToggleRow(model: model)
    }
}

private struct DataSharingToggleLabel: View {
    let title: LocalizedStringKey
    let isSaving: Bool

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if isSaving {
                ProgressView().controlSize(.small)
            }
        }
    }
}

#Preview("Data sharing rows") {
    let model = PrivacySecuritySettingsViewModel()
    model.telemetrySettings = PrivacyTelemetrySettingsProjection(exportEnabled: true, exportIntervalSeconds: 60)
    model.auditSettings = PrivacyAuditSettingsProjection(enabled: false)

    return Form {
        Section {
            DataSharingToggleRows(model: model)
        }
    }
    .environment(AppState())
}
