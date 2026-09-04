import Foundation
import Testing
@testable import MarmotKit
@testable import whitenoise_ios

@MainActor
struct AnalyticsConsentWithoutCredentialsTests {
    /// Sharing analytics is a consent preference, and Marmot stores it whether or
    /// not this build carries an OTLP bearer token. Refusing the write turned a
    /// missing build secret into a switch the user cannot move, which is what the
    /// data-sharing step showed: permanently off, with no way to say yes.
    @Test func analyticsPreferenceIsRecordableWithoutCredentials() async throws {
        let appState = AppState(
            client: try MarmotClient.testClient(),
            notifications: .shared,
            accountDefaults: IsolatedAccountDefaults.make()
        )
        await appState.bootstrap()
        _ = try await appState.createIdentity()
        #expect(!appState.telemetryBuildConfig.telemetryCredentialsAvailable)

        let stored = try await appState.setRelayTelemetryExportEnabled(true)

        #expect(stored.exportEnabled)
    }

    /// The switch the sheet renders must be movable in that same build.
    @Test func theSheetsAnalyticsToggleIsEnabledWithoutCredentials() async throws {
        let appState = AppState(
            client: try MarmotClient.testClient(),
            notifications: .shared,
            accountDefaults: IsolatedAccountDefaults.make()
        )
        await appState.bootstrap()
        _ = try await appState.createIdentity()

        let model = PrivacySecuritySettingsViewModel()
        await model.reload(using: appState)

        #expect(model.telemetrySettings != nil)
        #expect(!model.telemetryToggleDisabled)

        await model.setTelemetryEnabled(true, using: appState)

        #expect(model.telemetrySettings?.exportEnabled == true)
        #expect(model.telemetryErrorMessage == nil)
    }
}
