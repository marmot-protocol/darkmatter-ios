import Foundation
import MarmotKit

enum NotificationServiceRenderDecision: Equatable {
    case decorate(LocalNotificationPresentation, additionalPresentations: [LocalNotificationPresentation])
    /// Every presentable record in the wake belongs to a muted chat. The alert
    /// that woke the extension must still be delivered, but with generic
    /// content and no banner or sound.
    case deliverQuietly
    case fallback
}

nonisolated enum NotificationServiceTimeoutPolicy {
    static func shouldApplyTimeoutFallback(
        applyingFallbackForTimeout: Bool,
        didApplyRenderDecision: Bool
    ) -> Bool {
        applyingFallbackForTimeout && !didApplyRenderDecision
    }
}

nonisolated enum NotificationServiceSettingsReadPolicy {
    static func localNotificationsEnabled(readSetting: () throws -> Bool) -> Bool {
        do {
            return try readSetting()
        } catch {
            return true
        }
    }

    // `decision` invokes the `localNotificationsEnabled` predicate once per
    // record while filtering. The NSE's underlying predicate is a synchronous
    // `marmot.notificationSettings(accountRef:)` FFI read + decode, so an offline
    // backlog of N records issues N FFI reads inside the extension's tight (~8 s)
    // wake budget even though distinct accounts are typically 1–2. Wrap the read
    // so each distinct `accountRef` is resolved at most once per wake. The
    // predicate runs single-threaded on the NSE's MainActor while `decision`
    // filters synchronously, so a captured plain dictionary needs no locking.
    static func memoizingLocalNotificationsEnabled(
        read: @escaping (String) -> Bool
    ) -> (String) -> Bool {
        var cache: [String: Bool] = [:]
        return { accountRef in
            if let cached = cache[accountRef] {
                return cached
            }
            let resolved = read(accountRef)
            cache[accountRef] = resolved
            return resolved
        }
    }
}

nonisolated enum NotificationServiceProjection {
    // Keep room for extension startup and fallback delivery before iOS expires
    // the notification service extension.
    static let maxWakeWaitMs: UInt32 = 8_000

    // Upper bound on the number of *additional* message presentations the NSE
    // adds individually (the primary presentation woke the extension and is not
    // counted here). A large offline backlog can make `collectNotificationsAfterWake`
    // return dozens or hundreds of records; issuing one `UNUserNotificationCenter.add`
    // per record inside the extension's tight time budget risks expiration and floods
    // the user. Mirrors the bounding applied to other large/untrusted collections
    // (e.g. `DuckDuckGoImageSearchClient.maximumResultCount`).
    static let maxAdditionalPresentations = NotificationPresentationPolicy.maxAdditionalPresentations

    static func decision(
        for collection: BackgroundNotificationCollectionFfi,
        localNotificationsEnabled: (String) -> Bool = { _ in true },
        isArchived: (String, String) -> Bool = { _, _ in false },
        isMuted: (String, String) -> Bool = { _, _ in false },
        nickname: (String, String) -> String? = { _, _ in nil }
    ) -> NotificationServiceRenderDecision {
        NotificationPresentationPolicy.serviceDecision(
            for: collection,
            localNotificationsEnabled: localNotificationsEnabled,
            isArchived: isArchived,
            isMuted: isMuted,
            nickname: nickname
        )
    }

    // Caps how many additional records the NSE adds individually and folds any
    // overflow into a single summary presentation. The overflow records have
    // already been consumed from Marmot's background notification cursor, so they
    // must stay represented rather than be silently abandoned; the summary keeps
    // the consumed-cursor count visible without an unbounded `add` loop.
    static func boundedAdditionalPresentations(
        after primary: LocalNotificationPresentation,
        from additional: [LocalNotificationPresentation]
    ) -> [LocalNotificationPresentation] {
        NotificationPresentationPolicy.boundedAdditionalPresentations(
            after: primary,
            from: additional
        )
    }

    static func summaryPresentation(
        after primary: LocalNotificationPresentation,
        overflowCount: Int
    ) -> LocalNotificationPresentation {
        NotificationPresentationPolicy.summaryPresentation(
            after: primary,
            overflowCount: overflowCount
        )
    }
}
