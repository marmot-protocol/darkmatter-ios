import Foundation
import MarmotKit

@MainActor
protocol PrivacySecuritySettingsViewModelDataSource: AnyObject {
    var activeAccountRef: String? { get }

    func privacySecuritySettingsProjection() async throws -> PrivacySecuritySettingsProjection?
    func auditLogFileRows() async throws -> [AuditFileRow]?
    func setRelayTelemetryExportEnabled(_ enabled: Bool) async throws -> RelayTelemetrySettingsFfi
    func deleteAllAuditLogFiles() async throws
    func setAuditLogEnabled(_ enabled: Bool) async throws -> AuditLogSettingsFfi
    func auditLogUploadEndpoint() -> String?
    func postAuditLogFile(path: String, endpoint: String) async throws -> AuditLogUploadResultFfi
}

extension AppState: PrivacySecuritySettingsViewModelDataSource {}

/// Screen store for `PrivacySecuritySettingsView`: owns the telemetry/audit
/// settings projections, the audit-file list, and the save/delete actions, so
/// the view is pure rendering. The developer-mode toggles bind directly to
/// AppState prefs and stay in the view. Methods take an AppState-compatible
/// data source rather than retaining it.
@MainActor
@Observable
final class PrivacySecuritySettingsViewModel {
    var telemetrySettings: PrivacyTelemetrySettingsProjection?
    var auditSettings: PrivacyAuditSettingsProjection?
    var auditFileRows: [AuditFileRow] = []
    var telemetrySaving = false
    var auditSaving = false
    var auditDeleting = false
    var auditSendingPath: String?
    var pendingSendRow: AuditFileRow?
    var showDeleteAuditLogsConfirmation = false
    var filesLoading = false
    var telemetryErrorMessage: String?
    var auditErrorMessage: String?
    var errorMessage: String?
    var savedAt: Date?

    private var actionGate = AsyncActionGate()
    private var fullReloadRequestedAfterAction = false
    private var auditFilesReloadRequestedAfterAction = false

    var telemetryToggleDisabled: Bool {
        actionGate.isRunning || telemetrySaving || telemetrySettings == nil
    }

    var auditToggleDisabled: Bool {
        actionGate.isRunning || auditSaving || auditSettings == nil
    }

    var auditDeleteDisabled: Bool {
        actionGate.isRunning || auditDeleting || auditSaving
    }

    private func runAction(
        using dataSource: any PrivacySecuritySettingsViewModelDataSource,
        _ body: () async -> Void
    ) async {
        guard actionGate.tryBegin() else { return }
        await body()
        actionGate.end()
        await drainDeferredReload(using: dataSource)
    }

    private func requestFullReloadAfterAction() {
        fullReloadRequestedAfterAction = true
    }

    private func requestAuditFilesReloadAfterAction() {
        auditFilesReloadRequestedAfterAction = true
    }

    private func drainDeferredReload(using dataSource: any PrivacySecuritySettingsViewModelDataSource) async {
        if fullReloadRequestedAfterAction {
            fullReloadRequestedAfterAction = false
            auditFilesReloadRequestedAfterAction = false
            await reload(using: dataSource)
        } else if auditFilesReloadRequestedAfterAction {
            auditFilesReloadRequestedAfterAction = false
            await reloadAuditFiles(using: dataSource)
        }
    }

    private func deferOrReload(
        _ kind: PrivacySecuritySettingsReloadKind,
        using dataSource: any PrivacySecuritySettingsViewModelDataSource
    ) async {
        if actionGate.isRunning {
            switch kind {
            case .full:
                requestFullReloadAfterAction()
            case .auditFiles:
                requestAuditFilesReloadAfterAction()
            }
        } else {
            switch kind {
            case .full:
                await reload(using: dataSource)
            case .auditFiles:
                await reloadAuditFiles(using: dataSource)
            }
        }
    }

    private func canApplyReload(
        startedAt ticket: Int,
        accountRef: String?,
        using dataSource: any PrivacySecuritySettingsViewModelDataSource
    ) -> Bool {
        actionGate.canApplyReload(startedAt: ticket) && dataSource.activeAccountRef == accountRef
    }

    func reload(using dataSource: any PrivacySecuritySettingsViewModelDataSource) async {
        guard let reloadTicket = actionGate.reloadTicket() else {
            requestFullReloadAfterAction()
            return
        }
        let accountRef = dataSource.activeAccountRef
        filesLoading = true
        errorMessage = nil
        telemetryErrorMessage = nil
        auditErrorMessage = nil
        defer { filesLoading = false }

        do {
            guard let projection = try await dataSource.privacySecuritySettingsProjection() else { return }
            guard canApplyReload(startedAt: reloadTicket, accountRef: accountRef, using: dataSource) else {
                await deferOrReload(.full, using: dataSource)
                return
            }
            telemetrySettings = projection.telemetrySettings
            auditSettings = projection.auditSettings
            auditFileRows = projection.auditFileRows
        } catch {
            guard canApplyReload(startedAt: reloadTicket, accountRef: accountRef, using: dataSource) else {
                await deferOrReload(.full, using: dataSource)
                return
            }
            errorMessage = error.localizedDescription
        }
    }

    func reloadAuditFiles(using dataSource: any PrivacySecuritySettingsViewModelDataSource) async {
        guard let reloadTicket = actionGate.reloadTicket() else {
            requestAuditFilesReloadAfterAction()
            return
        }
        let accountRef = dataSource.activeAccountRef
        filesLoading = true
        auditErrorMessage = nil
        defer { filesLoading = false }

        do {
            guard let rows = try await dataSource.auditLogFileRows() else { return }
            guard canApplyReload(startedAt: reloadTicket, accountRef: accountRef, using: dataSource) else {
                await deferOrReload(.auditFiles, using: dataSource)
                return
            }
            auditFileRows = rows
        } catch {
            guard canApplyReload(startedAt: reloadTicket, accountRef: accountRef, using: dataSource) else {
                await deferOrReload(.auditFiles, using: dataSource)
                return
            }
            auditErrorMessage = error.localizedDescription
        }
    }

    func setTelemetryEnabled(_ enabled: Bool, using dataSource: any PrivacySecuritySettingsViewModelDataSource) async {
        guard !telemetrySaving else { return }
        guard let current = telemetrySettings else { return }
        await runAction(using: dataSource) {
            telemetrySaving = true
            telemetryErrorMessage = nil
            telemetrySettings = current.updatingExportEnabled(enabled)
            defer { telemetrySaving = false }

            do {
                telemetrySettings = PrivacyTelemetrySettingsProjection(
                    settings: try await dataSource.setRelayTelemetryExportEnabled(enabled)
                )
                savedAt = Date()
                Haptics.success()
            } catch {
                telemetrySettings = current
                Haptics.error()
                telemetryErrorMessage = error.localizedDescription
            }
        }
    }

    /// Uploads one audit file to the configured tracker endpoint. The engine
    /// validates the endpoint and attaches the tracker's bearer token itself.
    func sendAuditLog(row: AuditFileRow, using dataSource: any PrivacySecuritySettingsViewModelDataSource) async {
        guard auditSendingPath == nil,
              let endpoint = dataSource.auditLogUploadEndpoint() else { return }
        await runAction(using: dataSource) {
            auditSendingPath = row.path
            auditErrorMessage = nil
            defer { auditSendingPath = nil }

            do {
                _ = try await dataSource.postAuditLogFile(path: row.path, endpoint: endpoint)
                savedAt = Date()
                Haptics.success()
            } catch {
                auditErrorMessage = error.localizedDescription
                Haptics.error()
            }
        }
    }

    func deleteAllAuditLogs(using dataSource: any PrivacySecuritySettingsViewModelDataSource) async {
        guard !auditDeleting else { return }
        await runAction(using: dataSource) {
            auditDeleting = true
            auditErrorMessage = nil
            defer { auditDeleting = false }

            do {
                try await dataSource.deleteAllAuditLogFiles()
                // Clear the deleted rows immediately so they don't linger during the
                // follow-up reload.
                auditFileRows = []
                savedAt = Date()
                Haptics.success()
                await reloadAuditFiles(using: dataSource)
            } catch {
                Haptics.error()
                auditErrorMessage = error.localizedDescription
            }
        }
    }

    func setAuditEnabled(_ enabled: Bool, using dataSource: any PrivacySecuritySettingsViewModelDataSource) async {
        guard !auditSaving else { return }
        guard let current = auditSettings else { return }
        await runAction(using: dataSource) {
            auditSaving = true
            auditErrorMessage = nil
            auditSettings = PrivacyAuditSettingsProjection(enabled: enabled)
            defer { auditSaving = false }

            do {
                auditSettings = PrivacyAuditSettingsProjection(
                    settings: try await dataSource.setAuditLogEnabled(enabled)
                )
                savedAt = Date()
                Haptics.success()
                await reloadAuditFiles(using: dataSource)
            } catch {
                auditSettings = current
                Haptics.error()
                auditErrorMessage = error.localizedDescription
            }
        }
    }
}

private enum PrivacySecuritySettingsReloadKind {
    case full
    case auditFiles
}
