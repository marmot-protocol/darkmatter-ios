import Foundation
import Synchronization
import Testing
@testable import whitenoise_ios

struct NotificationAvatarBudgetTests {
    @Test func perFetchDeadlineIsClampedToTheRemainingBudget() {
        // Fresh budget: the per-fetch deadline applies unclamped.
        #expect(NotificationCommunicationDecorator.avatarFetchDeadline(
            elapsed: .zero,
            budget: .seconds(6),
            perFetch: .seconds(3)
        ) == .seconds(3))
        // Near-exhausted budget: a fetch may start but only gets the
        // remainder — the overshoot the loop-entry check allowed.
        #expect(NotificationCommunicationDecorator.avatarFetchDeadline(
            elapsed: .milliseconds(5_800),
            budget: .seconds(6),
            perFetch: .seconds(3)
        ) == .milliseconds(200))
        // Exhausted budget: no fetch starts.
        #expect(NotificationCommunicationDecorator.avatarFetchDeadline(
            elapsed: .seconds(6),
            budget: .seconds(6),
            perFetch: .seconds(3)
        ) == nil)
        #expect(NotificationCommunicationDecorator.avatarFetchDeadline(
            elapsed: .seconds(7),
            budget: .seconds(6),
            perFetch: .seconds(3)
        ) == nil)
    }

    @Test func deadlineWinCancelsTheAbandonedFetch() async {
        let observedCancellation = Mutex(false)
        let result = await NotificationCommunicationDecorator.withDeadline(.milliseconds(50)) {
            await withTaskCancellationHandler {
                try? await Task.sleep(for: .seconds(30))
                return nil
            } onCancel: {
                observedCancellation.withLock { $0 = true }
            }
        }
        #expect(result == nil)
        for _ in 0..<100 where !observedCancellation.withLock({ $0 }) {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(observedCancellation.withLock { $0 })
    }

    @Test func workWinReturnsItsValueBeforeTheDeadline() async {
        let result = await NotificationCommunicationDecorator.withDeadline(.seconds(30)) {
            Data([0x1])
        }
        #expect(result == Data([0x1]))
    }
}
