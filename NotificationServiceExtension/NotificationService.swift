import Foundation
import MarmotKit
import UserNotifications

@MainActor
final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    /// Communication-intent copy of the primary content. `updating(from:)`
    /// returns a new immutable content, so it rides in its own slot and
    /// `finish` prefers it unless the timeout fallback rewrote the original.
    private var decoratedContent: UNNotificationContent?
    private var collectionTask: Task<Void, Never>?
    private var expirationTask: Task<Void, Never>?
    private var additionalPresentationTask: Task<Void, Never>?
    private var avatarFetchTask: Task<[String: Data], Never>?
    private var activeMarmot: Marmot?
    private var activeMarmotNeedsShutdown = false
    private var didApplyRenderDecision = false
    private let maxNotificationServiceWaitMs = NotificationServiceProjection.maxWakeWaitMs

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)
        activeMarmot = nil
        activeMarmotNeedsShutdown = false
        additionalPresentationTask = nil
        avatarFetchTask = nil
        didApplyRenderDecision = false
        decoratedContent = nil

        collectionTask = Task { [weak self] in
            await self?.collectAndDecorateNotification()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        collectionTask?.cancel()
        // Unblocks the additional-presentation task: it enqueues immediately
        // with whatever avatars have resolved instead of waiting out the
        // remaining fetch deadlines.
        avatarFetchTask?.cancel()
        let additionalPresentationTask = additionalPresentationTask
        guard let marmot = takeActiveMarmotForShutdown() else {
            if let additionalPresentationTask {
                expirationTask = Task.detached { [weak self] in
                    await additionalPresentationTask.value
                    await self?.finish(applyingFallbackForTimeout: true)
                }
            } else {
                finish(applyingFallbackForTimeout: true)
            }
            return
        }
        expirationTask = Task.detached { [weak self] in
            let shutdownTask = Task.detached {
                await marmot.shutdown()
            }
            await additionalPresentationTask?.value
            await shutdownTask.value
            await self?.finish(applyingFallbackForTimeout: true)
        }
    }

    private func collectAndDecorateNotification() async {
        guard let content = bestAttemptContent else {
            finish()
            return
        }

        do {
            // An NSE wake is a sub-second drain on cold sockets; it must never
            // persist cursor advancement, or a partial catch-up permanently
            // floors the durable `since` past undelivered events.
            let marmot = try Marmot.newWithCursorPersistence(
                rootPath: AppContainerConfig.productionMarmotRoot().path,
                relayUrls: AppContainerConfig.seedRelays,
                cursorPersistence: .frozen
            )
            activeMarmot = marmot
            activeMarmotNeedsShutdown = true
            do {
                try await marmot.start()
                guard activeMarmot === marmot else { return }
                let result = try await marmot.collectNotificationsAfterWake(
                    maxWaitMs: maxNotificationServiceWaitMs,
                    source: .apnsNse
                )
                // One shared-defaults read per wake; per-record lookups hit the
                // in-memory snapshots. A nil mode snapshot means the shared suite
                // couldn't be resolved, so delivery fails safe (all suppressed).
                let notifyModeSnapshot = ChatMuteStore.notifyModeSnapshot()
                let contactNicknames = ContactNicknameStore.nicknamesByKey()
                let localNotificationsEnabled = NotificationServiceSettingsReadPolicy
                    .memoizingLocalNotificationsEnabled { accountRef in
                        NotificationServiceSettingsReadPolicy.localNotificationsEnabled {
                            try marmot.notificationSettings(
                                accountRef: accountRef
                            ).localNotificationsEnabled
                        }
                    }
                var rowsByAccountRef: [String: [ChatListRowFfi]] = [:]
                for accountRef in Set(result.notifications.map(\.accountRef)) {
                    rowsByAccountRef[accountRef] =
                        (try? marmot.chatList(accountRef: accountRef, includeArchived: true)) ?? []
                }
                let archivedChatKeys = NotificationServiceProjection.archivedChatKeys(
                    rowsByAccountRef: rowsByAccountRef
                )
                let decision = NotificationServiceProjection.decision(
                    for: result,
                    localNotificationsEnabled: localNotificationsEnabled,
                    isArchived: { accountRef, groupIdHex in
                        archivedChatKeys.contains(
                            NotificationServiceProjection.archivedChatKey(
                                accountRef: accountRef,
                                groupIdHex: groupIdHex
                            )
                        )
                    },
                    notifyMode: { accountIdHex, groupIdHex in
                        ChatMuteStore.notifyMode(
                            accountIdHex: accountIdHex,
                            groupIdHex: groupIdHex,
                            snapshot: notifyModeSnapshot
                        )
                    },
                    nickname: { ownerAccountIdHex, contactAccountIdHex in
                        ContactNicknameStore.nickname(
                            ownerAccountIdHex: ownerAccountIdHex,
                            contactAccountIdHex: contactAccountIdHex,
                            in: contactNicknames
                        )
                    }
                )
                // An empty wake can't be attributed: the engine drops
                // disabled accounts' records at ingest, so `.noData` is
                // ambiguous between "nothing existed" and "records were
                // suppressed". Account-wide inference gets both directions
                // wrong, so the fallback stays audible until the engine
                // reports suppressed records explicitly.
                await apply(decision, to: content)
            } catch {
                applyFallback(to: content)
            }
            if let marmot = takeActiveMarmotForShutdown(marmot) {
                await marmot.shutdown()
            }
        } catch {
            // Keep the provider payload generic when collection fails. The main
            // app will catch up when it next starts or receives a local event.
            applyFallback(to: content)
        }

        finish()
    }

    private func takeActiveMarmotForShutdown(_ marmot: Marmot? = nil) -> Marmot? {
        guard let active = activeMarmot else { return nil }
        if let marmot, active !== marmot { return nil }
        activeMarmot = nil
        defer { activeMarmotNeedsShutdown = false }
        guard activeMarmotNeedsShutdown else { return nil }
        return active
    }

    private func apply(
        _ decision: NotificationServiceRenderDecision,
        to content: UNMutableNotificationContent
    ) async {
        didApplyRenderDecision = true
        switch decision {
        case .decorate(let presentation, let additionalPresentations):
            // Enrich the deliverable content BEFORE any avatar work: an
            // expiration that lands mid-fetch must deliver the decorated
            // title/body, just without the intent image.
            decorate(content, with: presentation)
            // The additional-presentation task must exist before any avatar
            // await — expiration finishes without one, and these records are
            // already consumed from the background cursor. It awaits the
            // shared fetch internally; cancelling that fetch releases it to
            // enqueue with whatever resolved.
            let avatarFetch = Task { await Self.fetchAvatars(for: [presentation] + additionalPresentations) }
            avatarFetchTask = avatarFetch
            let additionalPresentationTask = startAdditionalPresentations(additionalPresentations) {
                await avatarFetch.value
            }
            let avatarsByUrl = await avatarFetch.value
            decoratedContent = NotificationCommunicationDecorator.decorated(
                content,
                presentation: presentation,
                avatarData: presentation.senderPictureUrl.flatMap { avatarsByUrl[$0] }
            )
            await additionalPresentationTask?.value
            self.additionalPresentationTask = nil
            avatarFetchTask = nil
        case .deliverQuietly:
            applyQuietDelivery(to: content)
        case .fallback:
            applyFallback(to: content)
        }
    }

    private func decorate(
        _ content: UNMutableNotificationContent,
        with presentation: LocalNotificationPresentation
    ) {
        NotificationContentDecorator.apply(presentation, to: content)
    }

    private func startAdditionalPresentations(
        _ additionalPresentations: [LocalNotificationPresentation],
        avatarsByUrl: @escaping @Sendable () async -> [String: Data]
    ) -> Task<Void, Never>? {
        guard !additionalPresentations.isEmpty else { return nil }
        let task = Task { [additionalPresentations] in
            let avatars = await avatarsByUrl()
            for presentation in additionalPresentations {
                let content = NotificationCommunicationDecorator.decorated(
                    NotificationContentDecorator.makeContent(for: presentation),
                    presentation: presentation,
                    avatarData: presentation.senderPictureUrl.flatMap { avatars[$0] }
                )
                let request = UNNotificationRequest(
                    identifier: presentation.identifier,
                    content: content,
                    trigger: nil
                )
                try? await UNUserNotificationCenter.current().add(request)
            }
        }
        additionalPresentationTask = task
        return task
    }

    /// Resolves each distinct sender avatar once per wake. Each fetch's
    /// deadline is clamped to what remains of the aggregate budget, so the
    /// total avatar wait is a hard bound rather than a loop-entry check that
    /// a late fetch could overshoot; cache hits are instant and unbudgeted.
    private static func fetchAvatars(
        for presentations: [LocalNotificationPresentation]
    ) async -> [String: Data] {
        var distinct: [String] = []
        for presentation in presentations {
            if let url = presentation.senderPictureUrl, !distinct.contains(url) {
                distinct.append(url)
            }
        }
        var avatars: [String: Data] = [:]
        let clock = ContinuousClock()
        let start = clock.now
        for url in distinct.prefix(3) {
            guard !Task.isCancelled,
                  let deadline = NotificationCommunicationDecorator.avatarFetchDeadline(
                      elapsed: clock.now - start
                  )
            else { break }
            if let data = await NotificationCommunicationDecorator.avatarData(
                for: url,
                deadline: deadline
            ) {
                avatars[url] = data
            }
        }
        return avatars
    }

    /// Without the filtering entitlement the extension cannot drop the alert
    /// that woke it, so a fully muted wake keeps the generic content but sheds
    /// its banner and sound: the record lands silently in Notification Center.
    private func applyQuietDelivery(to content: UNMutableNotificationContent) {
        applyFallback(to: content)
        content.sound = nil
        content.interruptionLevel = .passive
    }

    private func applyFallback(to content: UNMutableNotificationContent) {
        if content.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.title = L10n.string("White Noise")
        }
        if content.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            content.body = L10n.string("New encrypted message")
        }
    }

    private func finish(applyingFallbackForTimeout: Bool = false) {
        guard let contentHandler, let bestAttemptContent else { return }
        var deliverable: UNNotificationContent = bestAttemptContent
        if NotificationServiceTimeoutPolicy.shouldApplyTimeoutFallback(
            applyingFallbackForTimeout: applyingFallbackForTimeout,
            didApplyRenderDecision: didApplyRenderDecision
        ) {
            applyFallback(to: bestAttemptContent)
        } else if let decoratedContent {
            deliverable = decoratedContent
        }
        self.contentHandler = nil
        self.bestAttemptContent = nil
        self.collectionTask = nil
        self.expirationTask = nil
        self.additionalPresentationTask = nil
        self.didApplyRenderDecision = false
        self.decoratedContent = nil
        contentHandler(deliverable)
    }
}
