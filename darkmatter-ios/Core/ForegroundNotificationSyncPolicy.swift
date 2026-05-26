enum ForegroundNotificationSyncPolicy {
    static func shouldCatchUp(appPhase: AppState.Phase, isCatchUpRunning: Bool) -> Bool {
        appPhase == .ready && !isCatchUpRunning
    }
}
