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
        didApplyRenderDecision = false
        decoratedContent = nil

        collectionTask = Task { [weak self] in
            await self?.collectAndDecorateNotification()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        collectionTask?.cancel()
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
                let decision = NotificationServiceProjection.decision(
                    for: result,
                    localNotificationsEnabled: NotificationServiceSettingsReadPolicy
                        .memoizingLocalNotificationsEnabled { accountRef in
                            NotificationServiceSettingsReadPolicy.localNotificationsEnabled {
                                try marmot.notificationSettings(
                                    accountRef: accountRef
                                ).localNotificationsEnabled
                            }
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
            let avatarsByUrl = await Self.fetchAvatars(for: [presentation] + additionalPresentations)
            let additionalPresentationTask = startAdditionalPresentations(
                additionalPresentations,
                avatarsByUrl: avatarsByUrl
            )
            decorate(content, with: presentation)
            decoratedContent = NotificationCommunicationDecorator.decorated(
                content,
                presentation: presentation,
                avatarData: presentation.senderPictureUrl.flatMap { avatarsByUrl[$0] }
            )
            await additionalPresentationTask?.value
            self.additionalPresentationTask = nil
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
        avatarsByUrl: [String: Data]
    ) -> Task<Void, Never>? {
        guard !additionalPresentations.isEmpty else { return nil }
        let task = Task { [additionalPresentations] in
            for presentation in additionalPresentations {
                let content = NotificationCommunicationDecorator.decorated(
                    NotificationContentDecorator.makeContent(for: presentation),
                    presentation: presentation,
                    avatarData: presentation.senderPictureUrl.flatMap { avatarsByUrl[$0] }
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

    /// Resolves each distinct sender avatar once per wake. Cold fetches are
    /// individually bounded, and only the first few distinct senders are
    /// fetched so the extension's delivery budget is never spent on avatars.
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
        for url in distinct.prefix(3) {
            if let data = await NotificationCommunicationDecorator.avatarData(for: url) {
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
