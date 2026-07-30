import UserNotifications

@MainActor
final class OneShotNotificationDelivery {
    private var handler: ((UNNotificationContent) -> Void)?

    func reset(handler: @escaping (UNNotificationContent) -> Void) {
        self.handler = handler
    }

    @discardableResult
    func deliver(_ content: UNNotificationContent) -> Bool {
        guard let handler else { return false }
        self.handler = nil
        handler(content)
        return true
    }
}
