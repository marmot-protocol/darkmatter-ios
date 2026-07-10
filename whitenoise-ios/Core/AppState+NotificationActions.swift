import Foundation

extension AppState {
    /// Executes a notification-action response. Reply and mark-read may arrive
    /// while the app is backgrounded with the runtime suspended; the runtime is
    /// brought up and released again through the regular lifecycle pathways,
    /// held open by the same idempotent UIKit background-task helper the
    /// suspension path uses.
    @MainActor
    func performNotificationAction(_ operation: NotificationActionOperation) async {
        switch operation {
        case .openChat(let route):
            presentNotification(route: route)
        case .reply(let route, let text):
            await runNotificationAction(
                route: route,
                failureTitle: L10n.string("Reply not sent")
            ) { [notifications] client in
                _ = try await client.sendText(
                    accountRef: route.accountRef,
                    groupIdHex: route.groupIdHex,
                    text: text
                )
                // Replying implies the notified message was read. Best-effort:
                // a failed mark must not report the delivered reply as failed.
                if let messageIdHex = route.messageIdHex, !messageIdHex.isEmpty {
                    // The read cursor only advances for an initialized chat —
                    // the conversation screen normally does this on open.
                    _ = try? await client.initializeChatReadState(
                        accountRef: route.accountRef,
                        groupIdHex: route.groupIdHex
                    )
                    _ = await client.markTimelineMessagesRead(
                        accountRef: route.accountRef,
                        groupIdHex: route.groupIdHex,
                        messageIdHexes: [messageIdHex]
                    )
                }
                // The system only dismisses the acted-on notification; the
                // conversation's siblings are read now too.
                await notifications.removeDeliveredConversationNotifications(
                    accountRef: route.accountRef,
                    groupIdHex: route.groupIdHex
                )
                await self.refreshAccountUnreadSummaries()
            }
        case .markRead(let route, let messageIdHex):
            await runNotificationAction(
                route: route,
                failureTitle: L10n.string("Couldn't mark as read")
            ) { [notifications] client in
                // The read cursor only advances for an initialized chat — the
                // conversation screen normally does this on open.
                _ = try? await client.initializeChatReadState(
                    accountRef: route.accountRef,
                    groupIdHex: route.groupIdHex
                )
                let results = await client.markTimelineMessagesRead(
                    accountRef: route.accountRef,
                    groupIdHex: route.groupIdHex,
                    messageIdHexes: [messageIdHex]
                )
                guard results.contains(where: \.succeeded) else {
                    throw NotificationActionError.markReadFailed
                }
                await notifications.removeDeliveredConversationNotifications(
                    accountRef: route.accountRef,
                    groupIdHex: route.groupIdHex
                )
                await self.refreshAccountUnreadSummaries()
            }
        }
    }

    @MainActor
    private func runNotificationAction(
        route: LocalNotificationRoute,
        failureTitle: String,
        perform: @escaping @MainActor (MarmotClient) async throws -> Void
    ) async {
        let backgroundTask = BackgroundRuntimeSuspensionTask(name: "Notification action")
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runNotificationActionAgainstRuntime(
                route: route,
                failureTitle: failureTitle,
                perform: perform
            )
        }
        backgroundTask.endWhenSuspensionCompletes(task)
        await task.value
    }

    @MainActor
    private func runNotificationActionAgainstRuntime(
        route: LocalNotificationRoute,
        failureTitle: String,
        perform: @MainActor (MarmotClient) async throws -> Void
    ) async {
        // A cold background launch can deliver the response while bootstrap is
        // still bringing the runtime up; ride the existing bootstrap instead of
        // racing it.
        if phase == .bootstrapping {
            await bootstrap()
        }
        var failed = false
        do {
            let lease = try await runtimeLifecycle.startRuntimeForNotificationAction()
            do {
                try await perform(lease.client)
            } catch {
                failed = true
            }
            await runtimeLifecycle.suspendRuntimeAfterNotificationAction(lease)
        } catch {
            failed = true
        }
        if failed {
            await notifications.presentNotificationActionFailure(
                title: failureTitle,
                body: L10n.string("Open the chat to try again."),
                route: route
            )
        }
    }
}
