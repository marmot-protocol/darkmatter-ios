import Foundation
import OSLog

/// Privacy-safe host timings for user-visible actions that span SwiftUI and
/// Marmot calls. MDK owns its internal phase histograms; these measurements
/// cover the iOS orchestration around those calls.
@MainActor
enum HostActionPerformance {
    struct Token {
        fileprivate let startedAt = ContinuousClock.now
    }

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.ipf.whitenoise.ios",
        category: "host-performance"
    )
    private static var pendingGroupPresentations: [String: ContinuousClock.Instant] = [:]
    private static let maximumPendingGroupPresentations = 32

    static func begin() -> Token {
        Token()
    }

    static func record(_ operation: StaticString, since token: Token) {
        log.notice("\(operation): duration_ms=\(elapsedMilliseconds(since: token.startedAt), privacy: .public)")
    }

    static func groupBecameCanonical(groupIdHex: String, since token: Token) {
        if pendingGroupPresentations.count >= maximumPendingGroupPresentations,
           let oldest = pendingGroupPresentations.min(by: { $0.value < $1.value })?.key {
            pendingGroupPresentations.removeValue(forKey: oldest)
        }
        pendingGroupPresentations[groupIdHex] = token.startedAt
        log.notice(
            "group_create_canonical: duration_ms=\(elapsedMilliseconds(since: token.startedAt), privacy: .public)"
        )
    }

    static func groupNavigationRequested(groupIdHex: String) {
        guard let startedAt = pendingGroupPresentations[groupIdHex] else { return }
        log.notice(
            "group_create_navigation_requested: duration_ms=\(elapsedMilliseconds(since: startedAt), privacy: .public)"
        )
    }

    static func conversationBecameVisible(groupIdHex: String) {
        guard let startedAt = pendingGroupPresentations.removeValue(forKey: groupIdHex) else { return }
        log.notice(
            "group_create_conversation_visible: duration_ms=\(elapsedMilliseconds(since: startedAt), privacy: .public)"
        )
    }

    private static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> UInt64 {
        let elapsed = start.duration(to: ContinuousClock.now).components
        let milliseconds = Double(elapsed.seconds) * 1_000
            + Double(elapsed.attoseconds) / 1_000_000_000_000_000
        return UInt64(max(0, milliseconds).rounded())
    }
}
