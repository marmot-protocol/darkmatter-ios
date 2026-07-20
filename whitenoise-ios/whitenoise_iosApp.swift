import MarmotKit
import SwiftUI
import UIKit

@MainActor
final class BackgroundRuntimeSuspensionTask {
    typealias BeginBackgroundTask = @MainActor (
        _ name: String,
        _ expirationHandler: @escaping @Sendable () -> Void
    ) -> UIBackgroundTaskIdentifier
    typealias EndBackgroundTask = @MainActor (_ taskID: UIBackgroundTaskIdentifier) -> Void

    private let endBackgroundTask: EndBackgroundTask
    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private var suspensionTask: Task<Void, Never>?
    private var endObserverTask: Task<Void, Never>?

    init(
        name: String,
        beginBackgroundTask: BeginBackgroundTask = { name, expirationHandler in
            UIApplication.shared.beginBackgroundTask(
                withName: name,
                expirationHandler: expirationHandler
            )
        },
        endBackgroundTask: @escaping EndBackgroundTask = { taskID in
            UIApplication.shared.endBackgroundTask(taskID)
        }
    ) {
        self.endBackgroundTask = endBackgroundTask
        taskID = beginBackgroundTask(name) { [weak self] in
            guard let owner = self else { return }
            Task { @MainActor in
                owner.beginEndObserverIfPossible()
            }
        }
    }

    func endWhenSuspensionCompletes(_ suspensionTask: Task<Void, Never>) {
        self.suspensionTask = suspensionTask
        beginEndObserverIfPossible()
    }

    func endIfNeeded() {
        guard taskID != .invalid else { return }
        let taskIDToEnd = taskID
        taskID = .invalid
        endObserverTask?.cancel()
        endObserverTask = nil
        endBackgroundTask(taskIDToEnd)
    }

    private func beginEndObserverIfPossible() {
        guard endObserverTask == nil else { return }
        guard let suspensionTask else { return }
        endObserverTask = Task { @MainActor in
            await suspensionTask.value
            self.endIfNeeded()
        }
    }
}

@main
struct whitenoise_iosApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var appState: AppState
    @State private var appLockOverlay = AppLockOverlayPresenter()
    @State private var captureProtection = WindowCaptureProtection()

    init() {
        let appState = AppState()
        _appState = State(initialValue: appState)
        MessageRetentionBackgroundRefresh.shared.configure(appState: appState)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(appState.toastState)
                .environment(appState.navigation)
                .appAppearance()
                .task {
                    // The path monitor lives in this lazy singleton; touch it
                    // at launch so connectivity-restored events fire even in
                    // sessions that never read a media setting.
                    _ = MediaAutoDownloadStore.shared
                    appState.setAppSceneActive(scenePhase == .active)
                    appLockOverlay.update(for: appState.appLock.shield, controller: appState.appLock)
                    syncCaptureProtection()
                    if scenePhase == .active {
                        appState.appLock.handleScenePhaseActive()
                        Task { await appState.appLock.requestUnlock() }
                    }
                    await appState.bootstrap()
                }
                .onOpenURL { url in
                    appState.handle(url: url)
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        appState.appLock.handleScenePhaseActive()
                        Task { await appState.appLock.requestUnlock() }
                        appState.startForegroundActivation()
                    case .inactive:
                        appState.appLock.handleScenePhaseInactive()
                        appState.setAppSceneActive(false)
                    case .background:
                        appState.appLock.handleScenePhaseBackground()
                        beginBackgroundRuntimeSuspension()
                    @unknown default:
                        appState.appLock.handleScenePhaseInactive()
                        appState.setAppSceneActive(false)
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: MediaAutoDownloadStore.connectivityRestored)) { _ in
                    // Relay recovery is otherwise foreground-driven; a network
                    // return with the app already open needs the same pump.
                    Task { await appState.catchUpAfterForegroundActivation() }
                }
                .onChange(of: appState.activeAccount?.accountIdHex, initial: true) { _, accountIdHex in
                    MediaAutoDownloadStore.shared.setActiveAccount(accountIdHex)
                }
                .onChange(of: appState.appLock.shield) { _, shield in
                    appLockOverlay.update(for: shield, controller: appState.appLock)
                }
                .onChange(of: appState.blockScreenshots) { _, _ in
                    syncCaptureProtection()
                }
        }
    }

    @MainActor
    private func beginBackgroundRuntimeSuspension() {
        MessageRetentionBackgroundRefresh.shared.schedule()
        let backgroundTask = BackgroundRuntimeSuspensionTask(name: "Suspend Marmot runtime")
        let suspensionTask = appState.startRuntimeSuspension()
        backgroundTask.endWhenSuspensionCompletes(suspensionTask)
    }

    @MainActor
    private func syncCaptureProtection() {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?
            .windows
            .first { $0.isKeyWindow }
        captureProtection.setActive(appState.blockScreenshots, window: window)
    }

}
