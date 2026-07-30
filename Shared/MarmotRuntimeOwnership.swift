import MarmotKit

extension MarmotKitError {
    var isRuntimeOwnershipContention: Bool {
        if case .RuntimeBusy = self { return true }
        return false
    }
}
