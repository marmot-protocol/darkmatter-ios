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
        // Generous poll: a starved runner may schedule the detached work task
        // (and its cancellation handler) tens of seconds late.
        for _ in 0..<300 where !observedCancellation.withLock({ $0 }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(observedCancellation.withLock { $0 })
    }

    @Test func callerCancellationResumesTheDeadlineWaitAndCancelsWork() async {
        // The deadline and the work are effectively infinite, so the await
        // below can only ever return through the caller-cancellation racer —
        // completion itself is the assertion, with no wall-clock comparison
        // to flake on a saturated parallel test runner.
        let observedCancellation = Mutex(false)
        let waiter = Task {
            await NotificationCommunicationDecorator.withDeadline(.seconds(100_000)) {
                await withTaskCancellationHandler {
                    try? await Task.sleep(for: .seconds(100_000))
                    return nil
                } onCancel: {
                    observedCancellation.withLock { $0 = true }
                }
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        let result = await waiter.value
        #expect(result == nil)
        for _ in 0..<300 where !observedCancellation.withLock({ $0 }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        #expect(observedCancellation.withLock { $0 })
    }

    @Test func warmSlotsDeduplicatePerUrlAndCapConcurrency() {
        var inFlight: Set<String> = []
        #expect(NotificationCommunicationDecorator.claimWarmSlot("a", in: &inFlight, limit: 2))
        // Same URL never claims a second slot.
        #expect(!NotificationCommunicationDecorator.claimWarmSlot("a", in: &inFlight, limit: 2))
        #expect(NotificationCommunicationDecorator.claimWarmSlot("b", in: &inFlight, limit: 2))
        // The cap bounds distinct peer-controlled hosts, not just duplicates.
        #expect(!NotificationCommunicationDecorator.claimWarmSlot("c", in: &inFlight, limit: 2))
        inFlight.remove("a")
        #expect(NotificationCommunicationDecorator.claimWarmSlot("c", in: &inFlight, limit: 2))
    }

    @Test func workWinReturnsItsValueBeforeTheDeadline() async {
        let result = await NotificationCommunicationDecorator.withDeadline(.seconds(30)) {
            Data([0x1])
        }
        #expect(result == Data([0x1]))
    }
}
