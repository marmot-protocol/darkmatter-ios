import Foundation
import MarmotKit
import UserNotifications

final class NotificationService: UNNotificationServiceExtension {
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var bestAttemptContent: UNMutableNotificationContent?
    private var collectionTask: Task<Void, Never>?

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        self.contentHandler = contentHandler
        bestAttemptContent = (request.content.mutableCopy() as? UNMutableNotificationContent)

        collectionTask = Task {
            await collectAndDecorateNotification()
        }
    }

    override func serviceExtensionTimeWillExpire() {
        collectionTask?.cancel()
        finish()
    }

    private func collectAndDecorateNotification() async {
        guard let content = bestAttemptContent else {
            finish()
            return
        }

        do {
            let marmot = try Marmot(
                rootPath: AppContainerConfig.productionMarmotRoot().path,
                relayUrls: AppContainerConfig.seedRelays
            )
            try await marmot.start()
            let result = try await marmot.collectNotificationsAfterWake(
                maxWaitMs: 25_000,
                source: .apnsNse
            )

            if let update = result.notifications
                .filter({ !$0.isFromSelf })
                .max(by: { $0.timestampMs < $1.timestampMs }) {
                decorate(content, with: update)
            }
        } catch {
            // Keep the provider payload generic when collection fails. The main
            // app will catch up when it next starts or receives a local event.
        }

        finish()
    }

    private func decorate(_ content: UNMutableNotificationContent, with update: NotificationUpdateFfi) {
        guard let presentation = LocalNotificationProjection.makePresentation(for: update) else {
            return
        }
        content.title = presentation.title
        content.body = presentation.body
        content.threadIdentifier = presentation.threadIdentifier
        content.userInfo = presentation.userInfo
    }

    private func finish() {
        guard let contentHandler, let bestAttemptContent else { return }
        self.contentHandler = nil
        contentHandler(bestAttemptContent)
    }
}
