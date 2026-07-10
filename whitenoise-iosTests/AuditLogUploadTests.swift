import Testing
import Foundation
import MarmotKit
@testable import whitenoise_ios

/// The audit upload endpoint flows from build config into the engine's
/// tracker (automatic uploads) and gates the manual send action.
struct AuditLogUploadConfigTests {

    @Test func endpointReadFromInfoDictionary() {
        let config = TelemetryBuildConfig.current(
            infoDictionary: ["WhiteNoiseAuditLogEndpoint": "https://goggles.example/upload"],
            environment: [:]
        )
        #expect(config.auditLogEndpoint == "https://goggles.example/upload")
    }

    @Test func endpointFallsBackToEnvironment() {
        let config = TelemetryBuildConfig.current(
            infoDictionary: [:],
            environment: ["WHITENOISE_AUDIT_LOG_ENDPOINT": "https://goggles.example/env"]
        )
        #expect(config.auditLogEndpoint == "https://goggles.example/env")
    }

    @Test func unresolvedBuildSettingReadsAsAbsent() {
        let config = TelemetryBuildConfig.current(
            infoDictionary: ["WhiteNoiseAuditLogEndpoint": "$(WHITENOISE_AUDIT_LOG_ENDPOINT)"],
            environment: [:]
        )
        #expect(config.auditLogEndpoint == nil)
    }

    @Test func trackerConfigCarriesTheEndpoint() {
        let config = TelemetryBuildConfig.current(
            infoDictionary: ["WhiteNoiseAuditLogEndpoint": "https://goggles.example/upload"],
            environment: [:]
        )
        #expect(config.auditTrackerConfig().endpoint == "https://goggles.example/upload")
    }

    @Test func trackerConfigOmitsEndpointWhenUnconfigured() {
        let config = TelemetryBuildConfig.current(infoDictionary: [:], environment: [:])
        #expect(config.auditTrackerConfig().endpoint == nil)
    }
}

@MainActor
private final class SendAuditLogDataSourceFake: PrivacySecuritySettingsViewModelDataSource {
    var activeAccountRef: String? = "account"
    var endpoint: String? = "https://goggles.example/upload"
    var postedPaths: [String] = []
    var postedEndpoints: [String] = []
    var postError: Error?

    func privacySecuritySettingsProjection() async throws -> PrivacySecuritySettingsProjection? { nil }
    func auditLogFileRows() async throws -> [AuditFileRow]? { [] }
    func setRelayTelemetryExportEnabled(_ enabled: Bool) async throws -> RelayTelemetrySettingsFfi {
        throw TelemetrySettingsActionError.telemetryNotConfigured
    }
    func deleteAllAuditLogFiles() async throws {}
    func setAuditLogEnabled(_ enabled: Bool) async throws -> AuditLogSettingsFfi {
        throw TelemetrySettingsActionError.telemetryNotConfigured
    }
    func auditLogUploadEndpoint() -> String? { endpoint }
    func postAuditLogFile(path: String, endpoint: String) async throws -> AuditLogUploadResultFfi {
        if let postError { throw postError }
        postedPaths.append(path)
        postedEndpoints.append(endpoint)
        return AuditLogUploadResultFfi(path: path, status: 200, bytesSent: 1)
    }
}

@MainActor
struct SendAuditLogActionTests {
    private let row = AuditFileRow(fileName: "audit.jsonl", detailText: "1 KB", path: "/tmp/audit.jsonl")

    @Test func sendPostsTheRowToTheConfiguredEndpoint() async {
        let dataSource = SendAuditLogDataSourceFake()
        let model = PrivacySecuritySettingsViewModel()
        await model.sendAuditLog(row: row, using: dataSource)

        #expect(dataSource.postedPaths == ["/tmp/audit.jsonl"])
        #expect(dataSource.postedEndpoints == ["https://goggles.example/upload"])
        #expect(model.auditErrorMessage == nil)
        #expect(model.auditSendingPath == nil)
    }

    @Test func sendWithoutEndpointDoesNothing() async {
        let dataSource = SendAuditLogDataSourceFake()
        dataSource.endpoint = nil
        let model = PrivacySecuritySettingsViewModel()
        await model.sendAuditLog(row: row, using: dataSource)

        #expect(dataSource.postedPaths.isEmpty)
        #expect(model.auditErrorMessage == nil)
    }

    @Test func sendFailureSurfacesTheAuditError() async {
        let dataSource = SendAuditLogDataSourceFake()
        dataSource.postError = TelemetrySettingsActionError.telemetryNotConfigured
        let model = PrivacySecuritySettingsViewModel()
        await model.sendAuditLog(row: row, using: dataSource)

        #expect(dataSource.postedPaths.isEmpty)
        #expect(model.auditErrorMessage != nil)
        #expect(model.auditSendingPath == nil)
    }
}
