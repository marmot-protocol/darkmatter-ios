import Foundation
import Observation

@Observable
final class ToastState {
    private(set) var activeToast: Toast?

    @ObservationIgnored private var toastDismissTask: Task<Void, Never>?
    @ObservationIgnored private var expandedToastID: UUID?

    @MainActor
    func present(_ toast: Toast) {
        toastDismissTask?.cancel()
        activeToast = toast
        expandedToastID = nil
        scheduleDismissal(for: toast)
    }

    @MainActor
    func setExpanded(_ isExpanded: Bool, for toastID: UUID) {
        guard activeToast?.id == toastID else { return }
        expandedToastID = isExpanded ? toastID : nil
        toastDismissTask?.cancel()
        if !isExpanded, let activeToast {
            scheduleDismissal(for: activeToast)
        }
    }

    @MainActor
    private func scheduleDismissal(for toast: Toast) {
        let id = toast.id
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.sleepNanoseconds(forDuration: toast.duration))
            await MainActor.run {
                guard !Task.isCancelled,
                      let self,
                      self.activeToast?.id == id else { return }
                self.activeToast = nil
            }
        }
    }

    @MainActor
    func dismiss() {
        toastDismissTask?.cancel()
        expandedToastID = nil
        activeToast = nil
    }

    deinit {
        toastDismissTask?.cancel()
    }

    static func sleepNanoseconds(forDuration duration: TimeInterval) -> UInt64 {
        guard !duration.isNaN, duration > 0 else { return 0 }
        guard duration.isFinite else { return UInt64.max }
        let nanoseconds = duration * 1_000_000_000
        guard nanoseconds.isFinite,
              nanoseconds < TimeInterval(UInt64.max)
        else { return UInt64.max }
        return UInt64(nanoseconds)
    }
}
