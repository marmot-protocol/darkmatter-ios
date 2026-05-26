import MarmotKit

enum NativePushRegistrationPolicy {
    static func enabledAccountRefs(
        accounts: [AccountSummaryFfi],
        settingsFor: (String) -> NotificationSettingsFfi?
    ) -> [String] {
        accounts.compactMap { account in
            guard settingsFor(account.label)?.nativePushEnabled == true else { return nil }
            return account.label
        }
    }

    static func shouldRequestRemoteToken(accountRefs: [String], currentToken: String?) -> Bool {
        !accountRefs.isEmpty && (currentToken?.isEmpty ?? true)
    }
}
