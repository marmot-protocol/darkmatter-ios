import CryptoKit
import Foundation
import Intents
import Synchronization
import UserNotifications

/// Decorates message notifications as communication notifications so the
/// system renders the sender's avatar (initials monogram when no image is
/// available). Avatar fetching is bounded and cached in the app group so a
/// slow avatar host can never delay notification delivery.
nonisolated enum NotificationCommunicationDecorator {
    static let maxAvatarBytes = 512 * 1024
    static let avatarRequestTimeout: TimeInterval = 4
    /// Hard wall-clock bound per avatar resolution. The URLRequest timeout
    /// restarts across redirects and resolved endpoints, so delivery races
    /// this deadline instead and abandons the fetch when it loses.
    static let avatarDeadline: Duration = .seconds(3)
    static let maxCachedAvatars = 32

    static func decorated(
        _ content: UNNotificationContent,
        presentation: LocalNotificationPresentation,
        avatarData: Data?
    ) -> UNNotificationContent {
        guard let senderName = presentation.senderName, !senderName.isEmpty else { return content }
        let handle = personHandleValue(for: presentation)
        let sender = INPerson(
            personHandle: INPersonHandle(value: handle, type: .unknown),
            nameComponents: nil,
            displayName: senderName,
            image: avatarData.map(INImage.init(imageData:)),
            contactIdentifier: nil,
            customIdentifier: handle
        )
        let intent = INSendMessageIntent(
            recipients: nil,
            outgoingMessageType: .outgoingMessageText,
            content: presentation.body,
            speakableGroupName: presentation.isGroupConversation
                ? INSpeakableString(spokenPhrase: presentation.title)
                : nil,
            conversationIdentifier: presentation.threadIdentifier,
            serviceName: nil,
            sender: sender,
            attachments: nil
        )
        let interaction = INInteraction(intent: intent, response: nil)
        interaction.direction = .incoming
        interaction.donate(completion: nil)
        do {
            return try content.updating(from: intent)
        } catch {
            return content
        }
    }

    /// Stable per-sender identity: the account id survives display-name and
    /// nickname changes and keeps two same-named senders in one thread apart.
    private static func personHandleValue(for presentation: LocalNotificationPresentation) -> String {
        "\(presentation.threadIdentifier):\(presentation.senderAccountIdHex ?? presentation.senderName ?? "")"
    }

    // MARK: - Bounded, cached avatar bytes

    /// `pictureUrl` is re-validated even though presentations carry it
    /// pre-sanitized — the decorator is its own egress chokepoint.
    static func avatarData(for pictureUrl: String?) async -> Data? {
        guard let pictureUrl, let url = ContentSanitizer.imageURL(pictureUrl) else { return nil }
        if let cached = cachedAvatarData(for: url) { return cached }
        return await withDeadline(avatarDeadline) {
            guard let fetched = await boundedFetch(url) else { return nil }
            storeCachedAvatar(fetched, for: url)
            return fetched
        }
    }

    /// Resumes with the work's value or `nil` at the deadline, whichever comes
    /// first. A task group can't provide this bound: it awaits every child at
    /// scope exit, so a fetch stalled in non-cancellable DNS would hold the
    /// caller past `cancelAll()`. Here the loser is abandoned — a late fetch
    /// still finishes into the cache for the next wake.
    static func withDeadline(
        _ deadline: Duration,
        work: @escaping @Sendable () async -> Data?
    ) async -> Data? {
        let resumed = Mutex(false)
        return await withCheckedContinuation { continuation in
            Task.detached {
                let value = await work()
                let shouldResume = resumed.withLock { flag in
                    if flag { return false }
                    flag = true
                    return true
                }
                if shouldResume { continuation.resume(returning: value) }
            }
            Task.detached {
                try? await Task.sleep(for: deadline)
                let shouldResume = resumed.withLock { flag in
                    if flag { return false }
                    flag = true
                    return true
                }
                if shouldResume { continuation.resume(returning: nil) }
            }
        }
    }

    private static func boundedFetch(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = avatarRequestTimeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        guard let (data, response) = try? await PinnedHTTPSFetcher.fetch(
            request,
            maximumResponseBytes: maxAvatarBytes
        ) else { return nil }
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              !data.isEmpty
        else { return nil }
        return data
    }

    private static var cacheDirectory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppContainerConfig.appGroupIdentifier)?
            .appendingPathComponent("Library/Caches/NotificationAvatars", isDirectory: true)
    }

    private static func cacheFileURL(for url: URL) -> URL? {
        guard let cacheDirectory else { return nil }
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appendingPathComponent(name)
    }

    /// Cache entries expire so a changed image behind a stable URL converges;
    /// a stale hit reads as a miss and the re-fetch overwrites the file.
    static let avatarCacheLifetime: TimeInterval = 7 * 24 * 3600

    private static func cachedAvatarData(for url: URL, now: Date = Date()) -> Data? {
        guard let file = cacheFileURL(for: url),
              let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              now.timeIntervalSince(modified) < avatarCacheLifetime,
              let data = try? Data(contentsOf: file),
              !data.isEmpty, data.count <= maxAvatarBytes
        else { return nil }
        return data
    }

    private static func storeCachedAvatar(_ data: Data, for url: URL) {
        guard let cacheDirectory, let file = cacheFileURL(for: url) else { return }
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        pruneCache(in: cacheDirectory)
    }

    private static func pruneCache(in directory: URL) {
        let manager = FileManager.default
        guard let files = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ), files.count > maxCachedAvatars else { return }
        let sorted = files.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate < rhsDate
        }
        for file in sorted.prefix(files.count - maxCachedAvatars) {
            try? manager.removeItem(at: file)
        }
    }
}
