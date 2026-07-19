import Foundation
import Observation

nonisolated struct ConversationDraftKey: Hashable, Codable, Sendable {
    let accountRef: String
    let groupIdHex: String
}

nonisolated struct ConversationDraftMention: Codable, Equatable, Sendable {
    let utf16Location: Int
    let utf16Length: Int
    let displayName: String
    let npub: String
}

nonisolated struct ConversationDraftSnapshot: Equatable, Sendable {
    let text: String
    let mentions: [ConversationDraftMention]
}

nonisolated struct ConversationDraftEntry: Codable, Equatable, Sendable {
    let key: ConversationDraftKey
    let text: String
    let mentions: [ConversationDraftMention]
    let updatedAt: UInt64

    init(
        key: ConversationDraftKey,
        text: String,
        mentions: [ConversationDraftMention] = [],
        updatedAt: UInt64
    ) {
        self.key = key
        self.text = text
        self.mentions = mentions
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case key
        case text
        case mentions
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decode(ConversationDraftKey.self, forKey: .key)
        text = try container.decode(String.self, forKey: .text)
        mentions = try container.decodeIfPresent([ConversationDraftMention].self, forKey: .mentions) ?? []
        updatedAt = try container.decode(UInt64.self, forKey: .updatedAt)
    }
}

nonisolated enum ConversationDraftPreview {
    static let maximumLength = 140

    static func text(from draft: String?) -> String? {
        ContentSanitizer.singleLine(draft, maxLength: maximumLength)
    }
}

private nonisolated struct ConversationDraftDocument: Codable, Sendable {
    let version: Int
    let entries: [ConversationDraftEntry]
}

/// Serializes protected draft-file reads and writes away from the MainActor.
/// The actor performs each synchronous file operation without suspension, so
/// two rapid draft snapshots cannot complete out of order.
private actor ConversationDraftFile {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func load() -> [ConversationDraftEntry] {
        guard let data = try? Data(contentsOf: url),
              let document = try? JSONDecoder().decode(ConversationDraftDocument.self, from: data),
              document.version == 1
        else { return [] }
        return document.entries
    }

    func write(_ entries: [ConversationDraftEntry]) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        let protection: [FileAttributeKey: Any] = [
            .protectionKey: FileProtectionType.complete,
        ]
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: protection
        )
        try? manager.setAttributes(protection, ofItemAtPath: directory.path)

        if entries.isEmpty {
            try? manager.removeItem(at: url)
            return
        }

        let data = try JSONEncoder().encode(
            ConversationDraftDocument(version: 1, entries: entries)
        )
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        try? manager.setAttributes(protection, ofItemAtPath: url.path)
    }
}

/// Process-wide, account/group-scoped text-draft projection. Draft plaintext is
/// kept out of UserDefaults and written with complete file protection.
@MainActor
@Observable
final class ConversationDraftStore {
    static let maximumDraftCount = 200
    nonisolated static let maximumMentionsPerDraft = ContentSanitizer.maxMessageLength / 2
    static let saveDebounceNanoseconds: UInt64 = 250_000_000

    private var entries: [ConversationDraftKey: ConversationDraftEntry] = [:]
    private(set) var generation = 0

    @ObservationIgnored private let file: ConversationDraftFile
    @ObservationIgnored private var loadTask: Task<[ConversationDraftEntry], Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var didLoad = false

    init(fileURL: URL? = nil) {
        self.file = ConversationDraftFile(url: fileURL ?? Self.defaultFileURL())
    }

    isolated deinit {
        loadTask?.cancel()
        saveTask?.cancel()
    }

    func loadIfNeeded() async {
        if didLoad { return }
        if let loadTask {
            let loaded = await loadTask.value
            applyLoadedEntries(loaded)
            return
        }

        let file = file
        let task = Task { await file.load() }
        loadTask = task
        let loaded = await task.value
        guard !Task.isCancelled else { return }
        applyLoadedEntries(loaded)
    }

    func draft(accountRef: String, groupIdHex: String) -> String? {
        entries[ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)]?.text
    }

    func snapshot(accountRef: String, groupIdHex: String) -> ConversationDraftSnapshot? {
        guard let entry = entries[ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)]
        else { return nil }
        return ConversationDraftSnapshot(text: entry.text, mentions: entry.mentions)
    }

    func setDraft(_ text: String, accountRef: String, groupIdHex: String) {
        setDraft(
            ConversationDraftSnapshot(text: text, mentions: []),
            accountRef: accountRef,
            groupIdHex: groupIdHex
        )
    }

    func setDraft(_ snapshot: ConversationDraftSnapshot, accountRef: String, groupIdHex: String) {
        let key = ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)
        if let nextSnapshot = Self.normalizedStoredSnapshot(snapshot) {
            guard entries[key]?.text != nextSnapshot.text
                    || entries[key]?.mentions != nextSnapshot.mentions
            else { return }
            entries[key] = ConversationDraftEntry(
                key: key,
                text: nextSnapshot.text,
                mentions: nextSnapshot.mentions,
                updatedAt: UInt64(Date().timeIntervalSince1970)
            )
            pruneIfNeeded()
        } else {
            guard entries.removeValue(forKey: key) != nil else { return }
        }
        generation &+= 1
        scheduleSave()
    }

    func removeDraft(accountRef: String, groupIdHex: String) {
        setDraft("", accountRef: accountRef, groupIdHex: groupIdHex)
    }

    func removeDrafts(accountRef: String) {
        let previousCount = entries.count
        entries = entries.filter { $0.key.accountRef != accountRef }
        guard entries.count != previousCount else { return }
        generation &+= 1
        scheduleSave()
    }

    func flush() async {
        saveTask?.cancel()
        saveTask = nil
        let snapshot = entries.values.sorted { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            if lhs.key.accountRef != rhs.key.accountRef {
                return lhs.key.accountRef < rhs.key.accountRef
            }
            return lhs.key.groupIdHex < rhs.key.groupIdHex
        }
        try? await file.write(snapshot)
    }

    nonisolated static func normalizedStoredText(_ text: String) -> String? {
        let capped = String(text.prefix(ContentSanitizer.maxMessageLength))
        guard !capped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return capped
    }

    nonisolated static func normalizedStoredSnapshot(
        _ snapshot: ConversationDraftSnapshot
    ) -> ConversationDraftSnapshot? {
        guard let text = normalizedStoredText(snapshot.text) else { return nil }
        let units = Array(text.utf16)
        var previousEnd = 0
        let mentions = snapshot.mentions
            .sorted { lhs, rhs in lhs.utf16Location < rhs.utf16Location }
            .prefix(maximumMentionsPerDraft)
            .compactMap { mention -> ConversationDraftMention? in
                let (end, overflow) = mention.utf16Location.addingReportingOverflow(mention.utf16Length)
                guard mention.utf16Location >= previousEnd,
                      !overflow,
                      mention.utf16Length > 1,
                      end <= units.count,
                      ContentSanitizer.displayName(mention.displayName) == mention.displayName,
                      mention.npub.utf8.count == 63,
                      mention.npub.hasPrefix("npub1"),
                      NostrProfileReference.pubkeyHex(fromBech32: mention.npub) != nil
                else { return nil }
                let token = String(decoding: units[mention.utf16Location..<end], as: UTF16.self)
                guard token == "@\(mention.displayName)" else { return nil }
                previousEnd = end
                return mention
            }
        return ConversationDraftSnapshot(text: text, mentions: mentions)
    }

    private func applyLoadedEntries(_ loaded: [ConversationDraftEntry]) {
        guard !didLoad else { return }
        loadTask = nil
        for entry in loaded.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            guard entries[entry.key] == nil,
                  let text = Self.normalizedStoredText(entry.text)
            else { continue }
            entries[entry.key] = ConversationDraftEntry(
                key: entry.key,
                text: text,
                mentions: Self.normalizedStoredSnapshot(ConversationDraftSnapshot(
                    text: text,
                    mentions: entry.mentions
                ))?.mentions ?? [],
                updatedAt: entry.updatedAt
            )
        }
        pruneIfNeeded()
        didLoad = true
        generation &+= 1
    }

    private func pruneIfNeeded() {
        guard entries.count > Self.maximumDraftCount else { return }
        let keep = entries.values
            .sorted { lhs, rhs in
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.key.groupIdHex < rhs.key.groupIdHex
            }
            .prefix(Self.maximumDraftCount)
        entries = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0) })
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.saveDebounceNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    private nonisolated static func defaultFileURL() -> URL {
        let root = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return root
            .appendingPathComponent("White Noise", isDirectory: true)
            .appendingPathComponent("Drafts", isDirectory: true)
            .appendingPathComponent("conversation-drafts.json", isDirectory: false)
    }
}
