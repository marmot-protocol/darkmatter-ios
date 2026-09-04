import Foundation

/// Which identities have already been offered the one-time data-sharing choice.
///
/// Records only *that* an account was asked, never what it answered: the answer
/// is the pair of Marmot settings the sheet writes through to, which Marmot owns
/// per account. A second copy of the answer here could disagree with the runtime
/// the exports actually run on.
nonisolated enum DataSharingOptInStore {
    static let storageKey = "dataSharing.offeredAccountIdHexes"

    /// Storage form of an account id: callers that disagree on case or stray
    /// whitespace must address the same record. `nil` for a blank id, which
    /// cannot be recorded and so must never be treated as asked.
    static func normalized(_ accountIdHex: String) -> String? {
        let trimmed = accountIdHex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? nil : trimmed
    }

    static func offeredAccountIdHexes(defaults: UserDefaults) -> Set<String> {
        Set((defaults.stringArray(forKey: storageKey) ?? []).compactMap(normalized))
    }

    static func markOffered(accountIdHex: String, defaults: UserDefaults) {
        guard let accountIdHex = normalized(accountIdHex) else { return }
        var offered = offeredAccountIdHexes(defaults: defaults)
        guard offered.insert(accountIdHex).inserted else { return }
        write(offered, to: defaults)
    }

    /// Drop the record for a wiped identity, so a later sign-in with the same
    /// key is asked again rather than inheriting an answer it can no longer see.
    static func forget(accountIdHex: String, defaults: UserDefaults) {
        guard let accountIdHex = normalized(accountIdHex) else { return }
        var offered = offeredAccountIdHexes(defaults: defaults)
        guard offered.remove(accountIdHex) != nil else { return }
        write(offered, to: defaults)
    }

    private static func write(_ offered: Set<String>, to defaults: UserDefaults) {
        if offered.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else {
            defaults.set(offered.sorted(), forKey: storageKey)
        }
    }
}
