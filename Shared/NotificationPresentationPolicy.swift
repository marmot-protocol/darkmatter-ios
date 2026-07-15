import Foundation
import MarmotKit

nonisolated enum NotificationPresentationPolicy {
    static let maxAdditionalPresentations = 8

    static func shouldPresent(
        localNotificationsEnabled: Bool,
        isArchived: Bool = false,
        isMuted: Bool = false,
        appSceneActive: Bool,
        updateAccountRef: String,
        updateGroupIdHex: String,
        visibleAccountRef: String?,
        visibleGroupIdHex: String?
    ) -> Bool {
        guard localNotificationsEnabled, !isArchived, !isMuted else { return false }
        guard appSceneActive else { return true }
        guard let visibleAccountRef, let visibleGroupIdHex else { return true }
        return visibleAccountRef != updateAccountRef
            || visibleGroupIdHex != updateGroupIdHex
    }

    /// `isMuted` is keyed by (accountIdHex, groupIdHex) — the mute store's key —
    /// unlike `isArchived`, which takes the update's accountRef.
    static func serviceDecision(
        for collection: BackgroundNotificationCollectionFfi,
        localNotificationsEnabled: (String) -> Bool = { _ in true },
        isArchived: (String, String) -> Bool = { _, _ in false },
        isMuted: (String, String) -> Bool = { _, _ in false },
        nickname: (String, String) -> String? = { _, _ in nil }
    ) -> NotificationServiceRenderDecision {
        switch collection.status {
        case .newData:
            let updates = orderedPresentableUpdates(
                collection.notifications,
                localNotificationsEnabled: localNotificationsEnabled,
                isArchived: isArchived
            )
            let unmutedUpdates = updates.filter {
                !isMuted($0.accountIdHex, $0.groupIdHex)
            }
            // The alert that woke the extension cannot be dropped, so a wake
            // whose every presentable record is muted delivers quietly instead
            // of falling back to audible generic content.
            if unmutedUpdates.isEmpty, !updates.isEmpty {
                return .deliverQuietly
            }
            guard let primaryUpdate = unmutedUpdates.first,
                  let primary = LocalNotificationProjection.makePresentation(
                      for: primaryUpdate,
                      nickname: nickname
                  )
            else {
                return .fallback
            }
            return .decorate(
                primary,
                additionalPresentations: boundedAdditionalPresentations(
                    from: Array(unmutedUpdates.dropFirst()),
                    nickname: nickname
                )
            )
        case .noData, .failed:
            return .fallback
        }
    }

    static func orderedPresentableUpdates(
        _ updates: [NotificationUpdateFfi],
        localNotificationsEnabled: (String) -> Bool = { _ in true },
        isArchived: (String, String) -> Bool = { _, _ in false }
    ) -> [NotificationUpdateFfi] {
        updates
            .filter { update in
                shouldPresent(
                    localNotificationsEnabled: localNotificationsEnabled(update.accountRef),
                    isArchived: isArchived(update.accountRef, update.groupIdHex),
                    appSceneActive: false,
                    updateAccountRef: update.accountRef,
                    updateGroupIdHex: update.groupIdHex,
                    visibleAccountRef: nil,
                    visibleGroupIdHex: nil
                ) && !update.isFromSelf
            }
            .sorted(by: orderedBefore)
    }

    // Caps how many additional records the NSE adds individually and folds any
    // overflow into per-route summary presentations. The overflow records have
    // already been consumed from Marmot's background notification cursor, so
    // they must stay represented rather than be silently abandoned; the summary
    // keeps the consumed-cursor count visible without an unbounded `add` loop.
    static func boundedAdditionalPresentations(
        from additionalUpdates: [NotificationUpdateFfi],
        nickname: (String, String) -> String? = { _, _ in nil }
    ) -> [LocalNotificationPresentation] {
        guard additionalUpdates.count > maxAdditionalPresentations + 1 else {
            return additionalUpdates.compactMap {
                LocalNotificationProjection.makePresentation(for: $0, nickname: nickname)
            }
        }

        let shownUpdates = Array(additionalUpdates.prefix(maxAdditionalPresentations))
        let overflowUpdates = Array(additionalUpdates.dropFirst(maxAdditionalPresentations))
        return shownUpdates.compactMap {
            LocalNotificationProjection.makePresentation(for: $0, nickname: nickname)
        }
            + overflowSummaryPresentations(from: overflowUpdates, nickname: nickname)
    }

    static func overflowSummaryPresentations(
        from overflowUpdates: [NotificationUpdateFfi],
        nickname: (String, String) -> String? = { _, _ in nil }
    ) -> [LocalNotificationPresentation] {
        var buckets: [OverflowRouteKey: (first: NotificationUpdateFfi, count: Int)] = [:]
        var order: [OverflowRouteKey] = []
        for update in overflowUpdates {
            let key = OverflowRouteKey(update)
            if let existing = buckets[key] {
                buckets[key] = (existing.first, existing.count + 1)
            } else {
                buckets[key] = (update, 1)
                order.append(key)
            }
        }

        return order.compactMap { key in
            guard let bucket = buckets[key],
                  let base = LocalNotificationProjection.makePresentation(for: bucket.first, nickname: nickname)
            else { return nil }
            return summaryPresentation(after: base, overflowCount: bucket.count)
        }
    }

    static func summaryPresentation(
        after base: LocalNotificationPresentation,
        overflowCount: Int
    ) -> LocalNotificationPresentation {
        let route = LocalNotificationRoute(
            accountRef: base.route.accountRef,
            groupIdHex: base.route.groupIdHex,
            notificationKey: "\(base.route.notificationKey):+\(overflowCount)-more",
            messageIdHex: nil
        )

        return LocalNotificationPresentation(
            identifier: route.notificationKey,
            threadIdentifier: base.threadIdentifier,
            title: L10n.string("White Noise"),
            body: L10n.plural("%lld more messages", Int64(overflowCount)),
            route: route,
            timestamp: base.timestamp,
            userInfo: LocalNotificationProjection.userInfo(for: route)
        )
    }

    private static func orderedBefore(
        _ lhs: NotificationUpdateFfi,
        _ rhs: NotificationUpdateFfi
    ) -> Bool {
        if lhs.timestampMs != rhs.timestampMs {
            return lhs.timestampMs > rhs.timestampMs
        }
        return stableSortKey(lhs) < stableSortKey(rhs)
    }

    private static func stableSortKey(_ update: NotificationUpdateFfi) -> String {
        [
            update.accountRef,
            update.groupIdHex,
            update.conversationKey,
            update.notificationKey,
            update.messageIdHex ?? "",
            update.sender.accountIdHex
        ].joined(separator: "|")
    }

    private struct OverflowRouteKey: Hashable {
        let accountRef: String
        let groupIdHex: String
        let threadIdentifier: String

        init(_ update: NotificationUpdateFfi) {
            accountRef = update.accountRef
            groupIdHex = update.groupIdHex
            threadIdentifier = update.conversationKey.isEmpty
                ? "\(update.accountRef):\(update.groupIdHex)"
                : update.conversationKey
        }
    }
}
