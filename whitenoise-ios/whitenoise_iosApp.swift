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
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(appState.toastState)
                .environment(appState.navigation)
                .appAppearance()
                .task {
                    appState.setAppSceneActive(scenePhase == .active)
                    await appState.bootstrap()
                }
                .onOpenURL { url in
                    appState.handle(url: url)
                }
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        appState.startForegroundActivation()
                    case .inactive:
                        appState.setAppSceneActive(false)
                    case .background:
                        beginBackgroundRuntimeSuspension()
                    @unknown default:
                        appState.setAppSceneActive(false)
                    }
                }
        }
    }

    @MainActor
    private func beginBackgroundRuntimeSuspension() {
        let backgroundTask = BackgroundRuntimeSuspensionTask(name: "Suspend Marmot runtime")
        let suspensionTask = appState.startRuntimeSuspension()
        backgroundTask.endWhenSuspensionCompletes(suspensionTask)
    }

}
