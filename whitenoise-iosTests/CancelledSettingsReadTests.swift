import Foundation
import Testing
@testable import MarmotKit
@testable import whitenoise_ios

@MainActor
struct CancelledSettingsReadTests {
    private func readyAppState() async throws -> AppState {
        let appState = AppState(
            client: try MarmotClient.testClient(),
            notifications: .shared,
            accountDefaults: IsolatedAccountDefaults.make()
        )
        await appState.bootstrap()
        _ = try await appState.createIdentity()
        return appState
    }

    /// `.task(id:)` cancels and restarts whenever its id changes, and the sheet
    /// keys its reload on `activeAccountRef` — which moves while a fresh identity
    /// settles. The settings read refuses inside a cancelled task, and a refused
    /// read must not be mistaken for "no account": clearing both projections
    /// leaves both switches disabled with no retry, which is the sheet showing
    /// two switches that cannot be moved.
    @Test func aCancelledReloadKeepsTheSwitchesUsable() async throws {
        let appState = try await readyAppState()
        let model = PrivacySecuritySettingsViewModel()

        await model.reload(using: appState)
        #expect(model.telemetrySettings != nil)
        #expect(model.auditSettings != nil)

        let reload = Task { @MainActor in
            while !Task.isCancelled { await Task.yield() }
            await model.reload(using: appState)
        }
        reload.cancel()
        await reload.value

        #expect(model.telemetrySettings != nil)
        #expect(model.auditSettings != nil)
        #expect(!model.telemetryToggleDisabled)
        #expect(!model.auditToggleDisabled)
    }
}
