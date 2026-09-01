import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct MaintenanceDiagnosticsPresentationTests {
    @Test func maintenancePhasesHaveStableDeveloperLabels() {
        #expect(MaintenanceDiagnosticsPresentation.phaseLabel(.pendingPublication) == "Pending publication")
        #expect(MaintenanceDiagnosticsPresentation.phaseLabel(.clockSkewBlocked) == "Clock skew blocked")
        #expect(MaintenanceDiagnosticsPresentation.evolutionPhaseLabel(.attempting) == "Attempting")
        #expect(MaintenanceDiagnosticsPresentation.triggerLabel(.postJoin) == "Post-join")
    }

    @Test func peerControlledFailureCodeIsBoundedAndSanitized() throws {
        let code = try #require(MaintenanceDiagnosticsPresentation.failureCode(
            "  retry\u{202E}\nfailed  " + String(repeating: "x", count: 200)
        ))

        #expect(!code.contains("\u{202E}"))
        #expect(!code.contains("\n"))
        #expect(code.count <= 120)
    }

    @Test func hostileTimestampClampsWithoutTrapping() {
        #expect(MaintenanceDiagnosticsPresentation.date(UInt64.max) == .distantFuture)
        #expect(MaintenanceDiagnosticsPresentation.date(nil) == nil)
    }

    @Test func relayHealthIncludesConnectionAndForwarderFailures() {
        let lines = DiagnosticsView.relayHealthText(RelayHealthFfi(
            sdkBacked: true,
            totalRelays: 4,
            initialized: 4,
            pending: 0,
            connecting: 1,
            connected: 2,
            disconnected: 1,
            terminated: 0,
            banned: 0,
            sleeping: 0,
            connectionAttempts: 8,
            connectionSuccesses: 6,
            notificationForwarderRunning: false,
            notificationForwarderRestarts: 2,
            notificationForwarderLagIncidents: 3,
            notificationForwarderLaggedNotifications: 9,
            notificationForwarderPanics: 1,
            notificationForwarderUnexpectedExits: 1
        ))

        #expect(lines.count == 3)
        #expect(lines[0].contains("2/4 connected"))
        #expect(lines[1].contains("6/8 succeeded"))
        #expect(lines[2].contains("stopped"))
        #expect(lines[2].contains("1 panics"))
    }
}
