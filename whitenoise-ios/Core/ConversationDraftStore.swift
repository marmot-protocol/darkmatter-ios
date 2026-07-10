import Foundation
import Observation

nonisolated struct ConversationDraftKey: Hashable, Codable, Sendable {
    let accountRef: String
    let groupIdHex: String
}

nonisolated struct ConversationDraftEntry: Codable, Equatable, Sendable {
    let key: ConversationDraftKey
    let text: String
    let updatedAt: UInt64
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

    func setDraft(_ text: String, accountRef: String, groupIdHex: String) {
        let key = ConversationDraftKey(accountRef: accountRef, groupIdHex: groupIdHex)
        let nextText = Self.normalizedStoredText(text)
        if let nextText {
            guard entries[key]?.text != nextText else { return }
            entries[key] = ConversationDraftEntry(
                key: key,
                text: nextText,
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
