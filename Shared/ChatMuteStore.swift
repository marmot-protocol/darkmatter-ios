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

    /// The shared App Group suite, or `nil` when it cannot be resolved. A `nil`
    /// suite is a read *failure*, not "no chats muted" — never fall back to
    /// another domain (e.g. `.standard`) that the main app never wrote, because
    /// that reads back empty and silently unmutes every chat. Mute fails *safe*
    /// (treat as muted), the opposite polarity to `localNotificationsEnabled`.
    static var defaults: UserDefaults? {
        UserDefaults(suiteName: AppContainerConfig.appGroupIdentifier)
    }

    /// Composite storage key. Hex components are normalized so callers that
    /// disagree on case or stray whitespace still address the same chat, and
    /// blank or separator-bearing components are rejected so a missing or
    /// malformed account can never mute (or unmute) another account's chats.
    static func key(accountIdHex: String, groupIdHex: String) -> String? {
        guard let account = normalizedComponent(accountIdHex),
              let group = normalizedComponent(groupIdHex)
        else { return nil }
        return "\(account):\(group)"
    }

    static func mutedChatKeys(defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: storageKey) ?? [])
    }

    /// Resolving snapshot for in-app display. A `nil` suite reads as empty here;
    /// the extension uses `mutedChatKeysSnapshot()`, which keeps the failure
    /// distinguishable so the audible path can fail safe.
    static func mutedChatKeys() -> Set<String> {
        guard let defaults else { return [] }
        return mutedChatKeys(defaults: defaults)
    }

    /// Once-per-wake snapshot for the Notification Service Extension. `nil`
    /// signals the shared suite could not be resolved; pair it with
    /// `isMuted(accountIdHex:groupIdHex:snapshot:)`, which treats `nil` as
    /// "all muted".
    static func mutedChatKeysSnapshot() -> Set<String>? {
        guard let defaults else { return nil }
        return mutedChatKeys(defaults: defaults)
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

    /// Fail-safe read against a once-per-wake snapshot: a `nil` snapshot means
    /// the shared suite could not be resolved, so the chat is treated as muted.
    static func isMuted(
        accountIdHex: String,
        groupIdHex: String,
        snapshot: Set<String>?
    ) -> Bool {
        guard let snapshot else { return true }
        return isMuted(accountIdHex: accountIdHex, groupIdHex: groupIdHex, in: snapshot)
    }

    /// Resolving read for the main app. A `nil` suite fails safe (muted).
    static func isMuted(accountIdHex: String, groupIdHex: String) -> Bool {
        isMuted(
            accountIdHex: accountIdHex,
            groupIdHex: groupIdHex,
            snapshot: mutedChatKeysSnapshot()
        )
    }

    static func isMuted(
        accountIdHex: String,
        groupIdHex: String,
        defaults: UserDefaults
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
        defaults: UserDefaults
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

    /// Resolving write. No-op when the shared suite can't be resolved.
    static func setMuted(_ muted: Bool, accountIdHex: String, groupIdHex: String) {
        guard let defaults else { return }
        setMuted(muted, accountIdHex: accountIdHex, groupIdHex: groupIdHex, defaults: defaults)
    }

    /// Normalizes a key component and rejects blank or separator-bearing input.
    /// The `:` guard keeps the `account:group` join unambiguous at this
    /// documented trust boundary — without it, `("aa:bb", "cc")` and
    /// `("aa", "bb:cc")` would collide on the same key.
    private static func normalizedComponent(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty, !trimmed.contains(":") else { return nil }
        return trimmed
    }
}
