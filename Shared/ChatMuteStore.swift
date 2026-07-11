import Foundation

/// Per-device chat mute preference, keyed by (accountIdHex, groupIdHex).
///
/// Mute is app-side presentation state, not Marmot data, so it lives in the
/// shared App Group defaults — the same suite `AppLanguage` uses — where both
/// the main app and the Notification Service Extension read one source of
/// truth. Writes happen only from the main app's UI; the extension reads a
/// snapshot once per wake.
nonisolated enum ChatMuteStore {
    static let storageKey = "chats.mutedChatKeys"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: AppContainerConfig.appGroupIdentifier) ?? .standard
    }

    /// Composite storage key. Hex components are normalized so callers that
    /// disagree on case or stray whitespace still address the same chat, and
    /// blank components are rejected so a missing account can never mute (or
    /// unmute) another account's chats.
    static func key(accountIdHex: String, groupIdHex: String) -> String? {
        guard let account = normalizedComponent(accountIdHex),
              let group = normalizedComponent(groupIdHex)
        else { return nil }
        return "\(account):\(group)"
    }

    static func mutedChatKeys(defaults: UserDefaults = ChatMuteStore.defaults) -> Set<String> {
        Set(defaults.stringArray(forKey: storageKey) ?? [])
    }

    static func isMuted(
        accountIdHex: String,
        groupIdHex: String,
        in mutedChatKeys: Set<String>
    ) -> Bool {
        guard let key = key(accountIdHex: accountIdHex, groupIdHex: groupIdHex) else {
            return false
        }
        return mutedChatKeys.contains(key)
    }

    static func isMuted(
        accountIdHex: String,
        groupIdHex: String,
        defaults: UserDefaults = ChatMuteStore.defaults
    ) -> Bool {
        isMuted(
            accountIdHex: accountIdHex,
            groupIdHex: groupIdHex,
            in: mutedChatKeys(defaults: defaults)
        )
    }

    static func setMuted(
        _ muted: Bool,
        accountIdHex: String,
        groupIdHex: String,
        defaults: UserDefaults = ChatMuteStore.defaults
    ) {
        guard let key = key(accountIdHex: accountIdHex, groupIdHex: groupIdHex) else { return }
        var keys = mutedChatKeys(defaults: defaults)
        if muted {
            keys.insert(key)
        } else {
            keys.remove(key)
        }
        defaults.set(keys.sorted(), forKey: storageKey)
    }

    private static func normalizedComponent(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }
}
