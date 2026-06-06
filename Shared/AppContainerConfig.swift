import Foundation

enum AppContainerConfig {
    static let appGroupIdentifier = "group.dev.ipf.darkmatter"
    static let marmotDirectoryName = "Marmot"
    static let seedRelays = [
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.primal.net",
        "wss://relay.us.whitenoise.chat",
        "wss://relay.eu.whitenoise.chat"
    ]

    static func marmotRoot(in baseURL: URL) -> URL {
        baseURL.appendingPathComponent(marmotDirectoryName, isDirectory: true)
    }

    /// Resolves the per-app Application Support directory.
    ///
    /// Throws rather than degrading: the *only* acceptable roots for Marmot
    /// data are durable, backed-up locations. We must never silently fall back
    /// to `NSTemporaryDirectory()`, which iOS purges under storage pressure or
    /// after restarts — doing so would permanently destroy the user's MLS group
    /// state, message history, and account data with no warning.
    static func applicationSupportBase(fileManager: FileManager = .default) throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    static func sharedBase(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    }

    /// Resolves the on-disk root for the production Marmot store.
    ///
    /// Prefers the shared App Group container (so the app and its extensions
    /// share one store). Falls back to Application Support only when the App
    /// Group container is unavailable. If neither durable location can be
    /// resolved, this throws so the caller can surface a hard failure rather
    /// than writing data to a path that will disappear.
    static func productionMarmotRoot(fileManager: FileManager = .default) throws -> URL {
        guard let sharedBase = sharedBase(fileManager: fileManager) else {
            let legacyRoot = marmotRoot(in: try applicationSupportBase(fileManager: fileManager))
            ensureDirectoryExists(legacyRoot, fileManager: fileManager)
            return legacyRoot
        }

        let sharedRoot = marmotRoot(in: sharedBase)
        // Best-effort migration of any data written to the legacy Application
        // Support location before the App Group container became available. A
        // missing Application Support directory means there is nothing to
        // migrate, so don't fail the whole resolution over it.
        if let legacyBase = try? applicationSupportBase(fileManager: fileManager) {
            migrateLegacyRootIfNeeded(from: marmotRoot(in: legacyBase), to: sharedRoot, fileManager: fileManager)
        }
        ensureDirectoryExists(sharedRoot, fileManager: fileManager)
        return sharedRoot
    }

    static func migrateLegacyRootIfNeeded(from legacyRoot: URL, to sharedRoot: URL, fileManager: FileManager = .default) {
        guard legacyRoot.path != sharedRoot.path,
              fileManager.fileExists(atPath: legacyRoot.path),
              !fileManager.fileExists(atPath: sharedRoot.path)
        else { return }

        ensureDirectoryExists(sharedRoot.deletingLastPathComponent(), fileManager: fileManager)
        try? fileManager.moveItem(at: legacyRoot, to: sharedRoot)
    }

    static func ensureDirectoryExists(_ url: URL, fileManager: FileManager = .default) {
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

struct NativePushServerConfig: Equatable {
    static let serverPubkeyInfoKey = "DarkmatterPushServerPubkeyHex"
    static let relayHintInfoKey = "DarkmatterPushRelayHint"

    let serverPubkeyHex: String
    let relayHint: String?

    static func current(bundle: Bundle = .main) -> NativePushServerConfig? {
        guard let rawPubkey = bundle.object(forInfoDictionaryKey: serverPubkeyInfoKey) as? String else {
            return nil
        }
        let pubkey = rawPubkey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pubkey.isEmpty else { return nil }

        let rawRelayHint = bundle.object(forInfoDictionaryKey: relayHintInfoKey) as? String
        let relayHint = rawRelayHint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty

        return NativePushServerConfig(serverPubkeyHex: pubkey, relayHint: relayHint)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
