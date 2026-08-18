import MarmotKit

extension MarmotKitError {
    var isGroupUnrecoverableRepairRequired: Bool {
        if case .GroupUnrecoverableRepairRequired = self { return true }
        return false
    }

    var isAccountWorkerBusy: Bool {
        if case .AccountWorkerBusy = self { return true }
        return false
    }

    var isAccountWorkerResponseTimedOut: Bool {
        if case .AccountWorkerResponseTimedOut = self { return true }
        return false
    }

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
