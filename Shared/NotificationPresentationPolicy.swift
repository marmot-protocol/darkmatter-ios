import Foundation
import MarmotKit

nonisolated enum NotificationPresentationPolicy {
    static let maxAdditionalPresentations = 8

    static func shouldPresent(
        localNotificationsEnabled: Bool,
        isArchived: Bool = false,
        appSceneActive: Bool,
        updateAccountRef: String,
        updateGroupIdHex: String,
        visibleAccountRef: String?,
        visibleGroupIdHex: String?
    ) -> Bool {
        guard localNotificationsEnabled, !isArchived else { return false }
        guard appSceneActive else { return true }
        guard let visibleAccountRef, let visibleGroupIdHex else { return true }
        return visibleAccountRef != updateAccountRef
            || visibleGroupIdHex != updateGroupIdHex
    }

    static func serviceDecision(
        for collection: BackgroundNotificationCollectionFfi,
        localNotificationsEnabled: (String) -> Bool = { _ in true },
        isArchived: (String, String) -> Bool = { _, _ in false }
    ) -> NotificationServiceRenderDecision {
        switch collection.status {
        case .newData:
            let updates = orderedPresentableUpdates(
                collection.notifications,
                localNotificationsEnabled: localNotificationsEnabled,
                isArchived: isArchived
            )
            guard let primaryUpdate = updates.first,
                  let primary = LocalNotificationProjection.makePresentation(for: primaryUpdate)
            else {
                return .fallback
            }
            return .decorate(
                primary,
                additionalPresentations: boundedAdditionalPresentations(
                    from: Array(updates.dropFirst())
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

    static func boundedAdditionalPresentations(
        from additionalUpdates: [NotificationUpdateFfi]
    ) -> [LocalNotificationPresentation] {
        guard additionalUpdates.count > maxAdditionalPresentations + 1 else {
            return additionalUpdates.compactMap(LocalNotificationProjection.makePresentation(for:))
        }

        let shownUpdates = Array(additionalUpdates.prefix(maxAdditionalPresentations))
        let overflowUpdates = Array(additionalUpdates.dropFirst(maxAdditionalPresentations))
        return shownUpdates.compactMap(LocalNotificationProjection.makePresentation(for:))
            + overflowSummaryPresentations(from: overflowUpdates)
    }

    static func boundedAdditionalPresentations(
        after primary: LocalNotificationPresentation,
        from additional: [LocalNotificationPresentation]
    ) -> [LocalNotificationPresentation] {
        guard additional.count > maxAdditionalPresentations + 1 else {
            return additional
        }

        let shown = Array(additional.prefix(maxAdditionalPresentations))
        let overflow = additional.dropFirst(maxAdditionalPresentations)
        return shown + overflowSummaryPresentations(from: Array(overflow))
    }

    static func overflowSummaryPresentations(
        from overflowUpdates: [NotificationUpdateFfi]
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
                  let base = LocalNotificationProjection.makePresentation(for: bucket.first)
            else { return nil }
            return summaryPresentation(after: base, overflowCount: bucket.count)
        }
    }

    static func overflowSummaryPresentations(
        from overflow: [LocalNotificationPresentation]
    ) -> [LocalNotificationPresentation] {
        var buckets: [OverflowRouteKey: (first: LocalNotificationPresentation, count: Int)] = [:]
        var order: [OverflowRouteKey] = []
        for presentation in overflow {
            let key = OverflowRouteKey(presentation)
            if let existing = buckets[key] {
                buckets[key] = (existing.first, existing.count + 1)
            } else {
                buckets[key] = (presentation, 1)
                order.append(key)
            }
        }

        return order.compactMap { key in
            guard let bucket = buckets[key] else { return nil }
            return summaryPresentation(after: bucket.first, overflowCount: bucket.count)
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

        init(_ presentation: LocalNotificationPresentation) {
            accountRef = presentation.route.accountRef
            groupIdHex = presentation.route.groupIdHex
            threadIdentifier = presentation.threadIdentifier
        }
    }
}
