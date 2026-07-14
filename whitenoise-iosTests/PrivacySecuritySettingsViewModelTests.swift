import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

@MainActor
private final class MockPrivacyDataSource: PrivacySecuritySettingsViewModelDataSource {
    var activeAccountRef: String?
    var projection: PrivacySecuritySettingsProjection?
    var auditRows: [AuditFileRow]?
    var suspendProjection = false
    private var gate: CheckedContinuation<Void, Never>?

    func privacySecuritySettingsProjection() async throws -> PrivacySecuritySettingsProjection? {
        if suspendProjection {
            await withCheckedContinuation { gate = $0 }
        }
        return projection
    }

    func releaseSuspendedProjection() {
        gate?.resume()
        gate = nil
    }

    func auditLogFileRows() async throws -> [AuditFileRow]? { auditRows }
    func setRelayTelemetryExportEnabled(_ enabled: Bool) async throws -> RelayTelemetrySettingsFfi {
        throw CancellationError()
    }
    func deleteAllAuditLogFiles() async throws { throw CancellationError() }
    func setAuditLogEnabled(_ enabled: Bool) async throws -> AuditLogSettingsFfi {
        throw CancellationError()
    }
}

@MainActor
struct PrivacySecuritySettingsViewModelTests {
    /// Switching accounts must clear the previous account's toggles, audit rows,
    /// and save banner *before* the new account's projection read resolves, so a
    /// suspended read can't leave another account's privacy state on screen.
    @Test func accountSwitchClearsPreviousStateBeforeSuspendedProjectionResolves() async {
        let model = PrivacySecuritySettingsViewModel()
        let source = MockPrivacyDataSource()
        source.activeAccountRef = "account-a"
        source.projection = PrivacySecuritySettingsProjection(
            telemetrySettings: PrivacyTelemetrySettingsProjection(exportEnabled: true, exportIntervalSeconds: 60),
            auditSettings: PrivacyAuditSettingsProjection(enabled: true),
            auditFileRows: [AuditFileRow(fileName: "a.log", detailText: "1 KB - account-a", path: "/a.log")]
        )

        await model.reload(using: source)
        #expect(model.telemetrySettings != nil)
        #expect(model.auditSettings != nil)
        #expect(!model.auditFileRows.isEmpty)
        model.savedAt = Date()

        // Switch to account B with a suspended (hanging) projection read.
        source.activeAccountRef = "account-b"
        source.projection = nil
        source.suspendProjection = true
        let reloadTask = Task { await model.reload(using: source) }
        await Task.yield()
        await Task.yield()

        // The previous account's state is already cleared while the read hangs.
        #expect(model.telemetrySettings == nil)
        #expect(model.auditSettings == nil)
        #expect(model.auditFileRows.isEmpty)
        #expect(model.savedAt == nil)

        source.releaseSuspendedProjection()
        await reloadTask.value
    }

    /// A refresh of the same account must not blank the screen: the clear only
    /// fires on an account change.
    @Test func sameAccountReloadKeepsState() async {
        let model = PrivacySecuritySettingsViewModel()
        let source = MockPrivacyDataSource()
        source.activeAccountRef = "account-a"
        source.projection = PrivacySecuritySettingsProjection(
            telemetrySettings: PrivacyTelemetrySettingsProjection(exportEnabled: true, exportIntervalSeconds: 60),
            auditSettings: PrivacyAuditSettingsProjection(enabled: false),
            auditFileRows: [AuditFileRow(fileName: "a.log", detailText: "1 KB - account-a", path: "/a.log")]
        )

        await model.reload(using: source)
        await model.reload(using: source)

        #expect(model.telemetrySettings != nil)
        #expect(!model.auditFileRows.isEmpty)
    }
}
