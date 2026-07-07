struct VisibleChatRoute: Equatable {
    let accountRef: String
    let groupIdHex: String
}

enum LocalNotificationSuppressionPolicy {
    static func shouldPresent(
        localNotificationsEnabled: Bool,
        isArchived: Bool = false,
        appSceneActive: Bool,
        updateAccountRef: String,
        updateGroupIdHex: String,
        visibleChat: VisibleChatRoute?
    ) -> Bool {
        NotificationPresentationPolicy.shouldPresent(
            localNotificationsEnabled: localNotificationsEnabled,
            isArchived: isArchived,
            appSceneActive: appSceneActive,
            updateAccountRef: updateAccountRef,
            updateGroupIdHex: updateGroupIdHex,
            visibleAccountRef: visibleChat?.accountRef,
            visibleGroupIdHex: visibleChat?.groupIdHex
        )
    }
}
