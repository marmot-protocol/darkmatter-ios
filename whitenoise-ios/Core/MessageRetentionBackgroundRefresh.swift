import BackgroundTasks
import Foundation

nonisolated enum MessageRetentionBackgroundRefreshPolicy {
    static let fallbackBundleIdentifier = "dev.ipf.whitenoise.ios"
    static let suffix = "retention-sweep"
    static let earliestDelay: TimeInterval = 15 * 60

    static func taskIdentifier(bundleIdentifier: String?) -> String {
        "\(bundleIdentifier ?? fallbackBundleIdentifier).\(suffix)"
    }
}

/// Schedules best-effort iOS background refreshes for disappearing-message
/// cleanup. The task borrows RuntimeLifecycle's exclusive short-lived runtime
/// lease, so it never races the foreground runtime or leaves the App Group
/// SQLite store locked after iOS suspends the process.
@MainActor
final class MessageRetentionBackgroundRefresh {
    static let shared = MessageRetentionBackgroundRefresh()

    private weak var appState: AppState?
    private var registered = false

    private init() {}

    var taskIdentifier: String {
        MessageRetentionBackgroundRefreshPolicy.taskIdentifier(
            bundleIdentifier: Bundle.main.bundleIdentifier
        )
    }

    func configure(appState: AppState) {
        self.appState = appState
    }

    @discardableResult
    func register() -> Bool {
        guard !registered else { return true }
        registered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                self?.handle(refreshTask)
            }
        }
        return registered
    }

    @discardableResult
    func schedule() -> Bool {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(
            timeIntervalSinceNow: MessageRetentionBackgroundRefreshPolicy.earliestDelay
        )
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: taskIdentifier)
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            return false
        }
    }

    private func handle(_ task: BGAppRefreshTask) {
        schedule()
        guard let appState else {
            task.setTaskCompleted(success: false)
            return
        }
        let operation = Task { @MainActor in
            await appState.performBackgroundRetentionSweep()
        }
        task.expirationHandler = {
            operation.cancel()
        }
        Task { @MainActor in
            let succeeded = await operation.value
            task.setTaskCompleted(success: succeeded && !operation.isCancelled)
        }
    }
}
