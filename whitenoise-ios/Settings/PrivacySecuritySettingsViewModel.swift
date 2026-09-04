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
    func present(_ toast: Toast)
}

extension AppState: PrivacySecuritySettingsViewModelDataSource {}

extension PrivacySecuritySettingsViewModelDataSource {
    func present(_ toast: Toast) {}
}

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
    var showDeleteAuditLogsConfirmation = false
    var filesLoading = false
    var telemetryErrorMessage: String?
    var auditErrorMessage: String?
    var errorMessage: String?
    var savedAt: Date?

    private var actionGate = AsyncActionGate()
    private var fullReloadRequestedAfterAction = false
    private var auditFilesReloadRequestedAfterAction = false
    private var activeFileLoadIDs: Set<UUID> = []
    /// Account whose privacy state is currently shown. Used to clear
    /// account-scoped state before awaiting a *different* account's projection.
    private var loadedAccountRef: String?

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

    private func beginFileLoad() -> UUID {
        let id = UUID()
        activeFileLoadIDs.insert(id)
        filesLoading = true
        return id
    }

    private func endFileLoad(_ id: UUID) {
        activeFileLoadIDs.remove(id)
        filesLoading = !activeFileLoadIDs.isEmpty
    }

    func reload(using dataSource: any PrivacySecuritySettingsViewModelDataSource) async {
        guard let reloadTicket = actionGate.reloadTicket() else {
            requestFullReloadAfterAction()
            return
        }
        let accountRef = dataSource.activeAccountRef
        // Switching away from a *previously loaded* account: clear that account's
        // toggles, audit rows, and save banner before awaiting the new
        // projection, so this privacy screen never shows or lets you act on
        // another account's state during the suspended read. Deliberately not on
        // the first load (loadedAccountRef == nil): initial state is already
        // empty, and clearing there would wipe optimistic/seeded state a reload
        // started before a save is expected to preserve.
        if let loadedAccountRef, loadedAccountRef != accountRef {
            telemetrySettings = nil
            auditSettings = nil
            auditFileRows = []
            savedAt = nil
        }
        let fileLoadID = beginFileLoad()
        errorMessage = nil
        telemetryErrorMessage = nil
        auditErrorMessage = nil
        defer { endFileLoad(fileLoadID) }

        do {
            let loaded = try await dataSource.privacySecuritySettingsProjection()
            // Cancelled work publishes nothing. `.task(id:)` cancels and restarts
            // on every id change, and the replacement task performs its own read;
            // letting this one apply would race it. Deliberately not folded into
            // `canApplyReload`, whose failure path re-queues a reload — inside a
            // cancelled task that would refuse and re-queue forever.
            if Task.isCancelled { return }
            guard let projection = loaded else {
                guard canApplyReload(startedAt: reloadTicket, accountRef: accountRef, using: dataSource) else {
                    await deferOrReload(.full, using: dataSource)
                    return
                }
                // A nil projection means the read was *refused* — cancelled task,
                // suspended runtime, no live client — or that no account is
                // active. Only the latter may clear. Blanking the projections on a
                // refusal renders both switches from nil, which disables them with
                // nothing left to re-arm them: the data-sharing sheet, presented
                // while a fresh identity is still settling, showed exactly that.
                guard dataSource.activeAccountRef == nil else { return }
                telemetrySettings = nil
                auditSettings = nil
                auditFileRows = []
                loadedAccountRef = accountRef
                return
            }
            guard canApplyReload(startedAt: reloadTicket, accountRef: accountRef, using: dataSource) else {
                await deferOrReload(.full, using: dataSource)
                return
            }
            telemetrySettings = projection.telemetrySettings
            auditSettings = projection.auditSettings
            auditFileRows = projection.auditFileRows
            loadedAccountRef = accountRef
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
        let fileLoadID = beginFileLoad()
        auditErrorMessage = nil
        defer { endFileLoad(fileLoadID) }

        do {
            guard let rows = try await dataSource.auditLogFileRows() else {
                guard canApplyReload(startedAt: reloadTicket, accountRef: accountRef, using: dataSource) else {
                    await deferOrReload(.auditFiles, using: dataSource)
                    return
                }
                auditFileRows = []
                return
            }
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
                dataSource.present(.success(L10n.string("Done")))
            } catch {
                telemetrySettings = current
                // Also recorded inline: surfaces that present over the toast host
                // (the data-sharing sheet) would otherwise spring the switch back
                // with no explanation.
                telemetryErrorMessage = error.localizedDescription
                Haptics.error()
                dataSource.present(UserFacingError.toast(
                    title: L10n.string("Save failed"),
                    error: error
                ))
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
                dataSource.present(.success(L10n.string("Done")))
                await reloadAuditFiles(using: dataSource)
            } catch {
                Haptics.error()
                dataSource.present(UserFacingError.toast(
                    title: L10n.string("Delete failed"),
                    error: error
                ))
            }
        }
    }

    func setAuditEnabled(_ enabled: Bool, using dataSource: any PrivacySecuritySettingsViewModelDataSource) async {
        guard !auditSaving else { return }
        guard let current = auditSettings else { return }
        await runAction(using: dataSource) {
            auditSaving = true
            auditErrorMessage = nil
            auditSettings = current.updatingEnabled(enabled)
            defer { auditSaving = false }

            do {
                auditSettings = PrivacyAuditSettingsProjection(
                    settings: try await dataSource.setAuditLogEnabled(enabled)
                )
                savedAt = Date()
                Haptics.success()
                dataSource.present(.success(L10n.string("Done")))
                await reloadAuditFiles(using: dataSource)
            } catch {
                auditSettings = current
                auditErrorMessage = error.localizedDescription
                Haptics.error()
                dataSource.present(UserFacingError.toast(
                    title: L10n.string("Save failed"),
                    error: error
                ))
            }
        }
    }

}

private enum PrivacySecuritySettingsReloadKind {
    case full
    case auditFiles
}
