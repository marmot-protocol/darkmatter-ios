import Foundation
import Testing
import UserNotifications
@testable import MarmotKit
@testable import whitenoise_ios

private actor ScriptedRuntimeFactory {
    private var busyFailuresRemaining: Int
    private var attempts = 0
    private var constructionsInFlight = 0
    private var maximumConstructionsInFlight = 0

    init(busyFailures: Int) {
        busyFailuresRemaining = busyFailures
    }

    func allowNextConstructionToSucceed() {
        busyFailuresRemaining = 0
    }

    func make(
        rootPath: String,
        relayUrls: [String],
        cursorPersistence: CursorPersistenceFfi,
        telemetryConfig: TelemetryBuildConfig
    ) async throws -> MarmotClient {
        attempts += 1
        constructionsInFlight += 1
        maximumConstructionsInFlight = max(
            maximumConstructionsInFlight,
            constructionsInFlight
        )
        defer { constructionsInFlight -= 1 }

        if busyFailuresRemaining > 0 {
            busyFailuresRemaining -= 1
            throw MarmotKitError.RuntimeBusy
        }
        return try MarmotClient.testClient()
    }

    func snapshot() -> (attempts: Int, maximumInFlight: Int) {
        (attempts, maximumConstructionsInFlight)
    }
}

@MainActor
private func runtimeOwnershipDeniedNotifications() -> AppNotifications {
    AppNotifications(
        requestAuthorizationHandler: { false },
        authorizationStatusProvider: { .denied },
        remoteNotificationRegistrar: {}
    )
}

private actor RuntimeRetryGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var didEnter = false

    func sleep(_: Duration) async throws {
        didEnter = true
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        } onCancel: {
            Task { await self.release() }
        }
        try Task.checkCancellation()
    }

    func waitUntilEntered() async {
        while !didEnter {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
@Suite(.serialized)
struct RuntimeOwnershipTests {
    @Test func inactiveLaunchBootstrapsWithoutTreatingInactiveAsCancellation() async {
        let factory = ScriptedRuntimeFactory(busyFailures: 0)
        let appState = AppState(
            client: nil,
            notifications: runtimeOwnershipDeniedNotifications(),
            runtimeClientFactory: { rootPath, relayUrls, cursorPersistence, telemetryConfig in
                try await factory.make(
                    rootPath: rootPath,
                    relayUrls: relayUrls,
                    cursorPersistence: cursorPersistence,
                    telemetryConfig: telemetryConfig
                )
            }
        )
        appState.setAppSceneActive(false)

        await appState.bootstrap()

        #expect(appState.phase == .onboarding)
        #expect(appState.client != nil)
        let inactiveSnapshot = await factory.snapshot()
        #expect(inactiveSnapshot.attempts == 1)

        await appState.startRuntimeSuspension().value
    }

    @Test func bootstrapRetriesRuntimeBusySeriallyAndInstallsOneClient() async {
        let factory = ScriptedRuntimeFactory(busyFailures: 2)
        let appState = AppState(
            client: nil,
            notifications: runtimeOwnershipDeniedNotifications(),
            runtimeClientFactory: { rootPath, relayUrls, cursorPersistence, telemetryConfig in
                try await factory.make(
                    rootPath: rootPath,
                    relayUrls: relayUrls,
                    cursorPersistence: cursorPersistence,
                    telemetryConfig: telemetryConfig
                )
            },
            runtimeRetrySleeper: { _ in },
            runtimeConstructionRetryPolicy: RuntimeConstructionRetryPolicy(
                delays: [.zero, .zero, .zero]
            )
        )
        appState.setAppSceneActive(true)

        async let first: Void = appState.bootstrap()
        async let second: Void = appState.bootstrap()
        await first
        await second

        let snapshot = await factory.snapshot()
        #expect(snapshot.attempts == 3)
        #expect(snapshot.maximumInFlight == 1)
        #expect(appState.client != nil)
        #expect(appState.phase == .onboarding)
    }

    @Test func bootstrapStopsRetryingWhenAppBackgrounds() async {
        let factory = ScriptedRuntimeFactory(busyFailures: .max)
        let retryGate = RuntimeRetryGate()
        let appState = AppState(
            client: nil,
            notifications: runtimeOwnershipDeniedNotifications(),
            runtimeClientFactory: { rootPath, relayUrls, cursorPersistence, telemetryConfig in
                try await factory.make(
                    rootPath: rootPath,
                    relayUrls: relayUrls,
                    cursorPersistence: cursorPersistence,
                    telemetryConfig: telemetryConfig
                )
            },
            runtimeRetrySleeper: retryGate.sleep,
            runtimeConstructionRetryPolicy: RuntimeConstructionRetryPolicy(
                delays: [.seconds(10), .seconds(10)]
            )
        )
        appState.setAppSceneActive(true)
        let bootstrap = Task { await appState.bootstrap() }
        await retryGate.waitUntilEntered()

        appState.setAppSceneActive(false)
        await retryGate.release()
        await bootstrap.value

        let snapshot = await factory.snapshot()
        #expect(snapshot.attempts == 1)
        #expect(appState.client == nil)
        #expect(appState.phase == .bootstrapping)
    }

    @Test func exhaustedContentionIsRecoverableAndASecondBootstrapCanSucceed() async {
        let factory = ScriptedRuntimeFactory(busyFailures: 2)
        let appState = AppState(
            client: nil,
            notifications: runtimeOwnershipDeniedNotifications(),
            runtimeClientFactory: { rootPath, relayUrls, cursorPersistence, telemetryConfig in
                try await factory.make(
                    rootPath: rootPath,
                    relayUrls: relayUrls,
                    cursorPersistence: cursorPersistence,
                    telemetryConfig: telemetryConfig
                )
            },
            runtimeRetrySleeper: { _ in },
            runtimeConstructionRetryPolicy: RuntimeConstructionRetryPolicy(delays: [.zero])
        )
        appState.setAppSceneActive(true)

        await appState.bootstrap()

        guard case .failed(let message) = appState.phase else {
            Issue.record("Expected recoverable startup failure")
            return
        }
        #expect(message.contains("secure background operation"))
        #expect(!message.localizedCaseInsensitiveContains("database"))
        #expect(appState.client == nil)

        await factory.allowNextConstructionToSucceed()
        await appState.bootstrap()
        #expect(appState.phase == .onboarding)
        #expect(appState.client != nil)
    }

    @Test func backgroundSuspensionDropsTheFinalClientReference() async throws {
        var injectedClient: MarmotClient? = try MarmotClient.testClient()
        weak let releasedClient = injectedClient
        let appState = AppState(
            client: injectedClient,
            notifications: runtimeOwnershipDeniedNotifications()
        )
        injectedClient = nil
        appState.setAppSceneActive(true)
        await appState.bootstrap()

        await appState.startRuntimeSuspension().value

        #expect(appState.client == nil)
        #expect(releasedClient == nil)
    }

    @Test func runtimeLeaseRejectsASecondOwnerUntilTheFinalHandleDrops() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarmotLeaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var first: Marmot? = try Marmot.newWithCursorPersistence(
            rootPath: root.path,
            relayUrls: ["wss://relay.invalid.test"],
            cursorPersistence: .advance
        )

        do {
            _ = try Marmot.newWithCursorPersistence(
                rootPath: root.path,
                relayUrls: ["wss://relay.invalid.test"],
                cursorPersistence: .frozen
            )
            Issue.record("Expected the second runtime owner to be rejected")
        } catch let error as MarmotKitError {
            #expect(error.isRuntimeOwnershipContention)
        }

        await first?.shutdown()
        first = nil

        let replacement = try Marmot.newWithCursorPersistence(
            rootPath: root.path,
            relayUrls: ["wss://relay.invalid.test"],
            cursorPersistence: .advance
        )
        await replacement.shutdown()
    }

    @Test func notificationContentionUsesTypedImmediateFallbackClassification() {
        #expect(MarmotKitError.RuntimeBusy.isRuntimeOwnershipContention)
        #expect(!MarmotKitError.RuntimeStopping.isRuntimeOwnershipContention)
    }

    @Test func notificationActionContentionFailsImmediatelyAndReleasesSuspensionGate() async throws {
        var initialClient: MarmotClient? = try MarmotClient.testClient()
        let appState = AppState(
            client: initialClient,
            notifications: runtimeOwnershipDeniedNotifications(),
            runtimeClientFactory: { _, _, _, _ in
                throw MarmotKitError.RuntimeBusy
            }
        )
        initialClient = nil
        appState.setAppSceneActive(true)
        await appState.bootstrap()
        await appState.startRuntimeSuspension().value

        do {
            _ = try await appState.runtimeLifecycle.startRuntimeForNotificationAction()
            Issue.record("Expected notification action contention to fall back")
        } catch let error as NotificationActionError {
            guard case .runtimeUnavailable = error else {
                Issue.record("Unexpected notification action error")
                return
            }
        }

        #expect(!appState.runtimeLifecycle.isRuntimeSuspendingNow)
        #expect(appState.client == nil)
        #expect(appState.runtimeSuspendedForBackground)
    }

    @Test func notificationDeliveryGateWinsAnExpirationRaceExactlyOnce() {
        let gate = OneShotNotificationDelivery()
        var delivered: [String] = []
        gate.reset { delivered.append($0.title) }

        let timeoutFallback = UNMutableNotificationContent()
        timeoutFallback.title = "timeout fallback"
        let lateCollectionResult = UNMutableNotificationContent()
        lateCollectionResult.title = "late collection result"

        #expect(gate.deliver(timeoutFallback))
        #expect(!gate.deliver(lateCollectionResult))
        #expect(delivered == ["timeout fallback"])
    }
}
