import MarmotKit

extension MarmotKitError {
    var isRuntimeOwnershipContention: Bool {
        if case .RuntimeBusy = self { return true }
        return false
    }

    /// Startup can briefly race the NSE, a closing SQLite connection, or iOS
    /// making protected Keychain data available after unlock. These are safe
    /// to retry while the app remains on its bootstrap surface.
    var isTransientStartupReadinessFailure: Bool {
        switch self {
        case .RuntimeBusy, .StorageBusy, .KeystoreUnavailable:
            true
        default:
            false
        }
    }
}
