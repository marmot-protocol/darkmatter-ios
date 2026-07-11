import SwiftUI
import MarmotKit

@MainActor
protocol RelaysViewModelDataSource: AnyObject {
    var activeAccountRef: String? { get }

    func loadAccountRelayLists(accountRef: String) async throws -> AccountRelayListsFfi
    func saveAccountRelayLists(
        accountRef: String,
        relays: [String],
        currentLists: AccountRelayListsFfi?
    ) async throws -> AccountRelayListsFfi
    func present(_ toast: Toast)
}

extension AppState: RelaysViewModelDataSource {
    func loadAccountRelayLists(accountRef: String) async throws -> AccountRelayListsFfi {
        try await currentMarmotClient().accountRelayLists(accountRef: accountRef)
    }

    func saveAccountRelayLists(
        accountRef: String,
        relays: [String],
        currentLists: AccountRelayListsFfi?
    ) async throws -> AccountRelayListsFfi {
        let client = try currentMarmotClient()
        return try await RelaySettings.saveAccountRelays(
            accountRef: accountRef,
            relays: relays,
            currentLists: currentLists,
            manager: client
        )
    }
}

/// Screen store for `RelaysView`. Holds the relay-editing UI state and routes
/// reads/edits through Marmot (off the MainActor via `MarmotClient`), so the
/// view is pure rendering. The relay projection + validation live in the pure
/// `RelaySettings` helpers; this just orchestrates load/save and UI state.
///
/// Methods take an AppState-compatible data source rather than retaining it —
/// the view always has AppState via `@Environment`, and tests can drive the
/// async/reload interleavings without constructing a Marmot runtime.
@MainActor
@Observable
final class RelaysViewModel {
    var lists: AccountRelayListsFfi?
    var pendingUrl = ""
    var saveError: String?
    var savedAt: Date?

    private var actionGate = AsyncActionGate()
    private var reloadRequestedAfterSave = false
    private var queuedRelayDeletes: [String] = []

    var isSaving: Bool { actionGate.isRunning }

    var currentRelays: [String] {
        guard let lists else { return [] }
        return RelaySettings.editableRelays(from: lists)
    }

    var canAdd: Bool {
        guard lists != nil,
              !isSaving,
              let normalized = RelaySettings.normalizedRelayURL(pendingUrl)
        else { return false }
        return !currentRelays.contains(normalized)
    }

    private func requestReloadAfterSave() {
        reloadRequestedAfterSave = true
    }

    private func drainDeferredReload(using dataSource: any RelaysViewModelDataSource) async {
        guard reloadRequestedAfterSave else { return }
        reloadRequestedAfterSave = false
        await reload(using: dataSource)
    }

    private func deferOrReload(using dataSource: any RelaysViewModelDataSource) async {
        if actionGate.isRunning {
            requestReloadAfterSave()
        } else {
            await reload(using: dataSource)
        }
    }

    private func canApplyReload(
        startedAt ticket: Int,
        accountRef: String?,
        using dataSource: any RelaysViewModelDataSource
    ) -> Bool {
        actionGate.canApplyReload(startedAt: ticket) && dataSource.activeAccountRef == accountRef
    }

    func reload(using dataSource: any RelaysViewModelDataSource) async {
        guard let reloadTicket = actionGate.reloadTicket() else {
            requestReloadAfterSave()
            return
        }
        let accountRef = dataSource.activeAccountRef
        guard let ref = accountRef else {
            lists = nil
            return
        }
        do {
            let loadedLists = try await dataSource.loadAccountRelayLists(accountRef: ref)
            guard canApplyReload(startedAt: reloadTicket, accountRef: accountRef, using: dataSource) else {
                await deferOrReload(using: dataSource)
                return
            }
            lists = loadedLists
        } catch {
            guard canApplyReload(startedAt: reloadTicket, accountRef: accountRef, using: dataSource) else {
                await deferOrReload(using: dataSource)
                return
            }
            // Keep the last-known list on a transient reload failure rather than
            // blanking an already-loaded screen back to the loading state.
        }
    }

    func addPending(using dataSource: any RelaysViewModelDataSource) {
        guard let normalized = RelaySettings.normalizedRelayURL(pendingUrl), canAdd else { return }
        Task {
            if await save(currentRelays + [normalized], using: dataSource) {
                pendingUrl = ""
            }
        }
    }

    func deleteRelays(at indexSet: IndexSet, using dataSource: any RelaysViewModelDataSource) {
        let relays = currentRelays
        let urls = indexSet.compactMap { index in
            relays.indices.contains(index) ? relays[index] : nil
        }
        guard !urls.isEmpty else { return }
        if isSaving {
            queueRelayDeletes(urls)
            return
        }
        Task { _ = await deleteRelayURLs(urls, using: dataSource) }
    }

    @discardableResult
    func save(_ relays: [String], using dataSource: any RelaysViewModelDataSource) async -> Bool {
        // Serialize saves: an overlapping save would compute its next list from
        // stale `lists`/`currentRelays` and clobber the in-flight write.
        guard actionGate.tryBegin() else { return false }
        guard let accountRef = dataSource.activeAccountRef else {
            actionGate.end()
            await drainDeferredReload(using: dataSource)
            return false
        }
        let normalized = RelaySettings.normalizedRelayURLs(relays)
        guard !normalized.isEmpty else {
            actionGate.end()
            await drainDeferredReload(using: dataSource)
            saveError = L10n.string("Keep at least one relay.")
            Haptics.error()
            return false
        }

        saveError = nil

        do {
            let savedLists = try await dataSource.saveAccountRelayLists(
                accountRef: accountRef,
                relays: normalized,
                currentLists: lists
            )
            guard dataSource.activeAccountRef == accountRef else {
                requestReloadAfterSave()
                actionGate.end()
                await drainDeferredReload(using: dataSource)
                return false
            }
            lists = savedLists
            savedAt = Date()
            Haptics.success()
            dataSource.present(.success(L10n.string("Relay lists updated")))
            actionGate.end()
            await drainQueuedRelayDeletes(using: dataSource)
            await drainDeferredReload(using: dataSource)
            return true
        } catch {
            if let failure = error as? RelaySettingsSaveFailure,
               let reloadedLists = failure.reloadedLists {
                lists = reloadedLists
            }
            Haptics.error()
            saveError = error.localizedDescription
            dataSource.present(.error(L10n.string("Relay update failed"), message: error.localizedDescription))
            actionGate.end()
            await drainDeferredReload(using: dataSource)
            return false
        }
    }

    private func queueRelayDeletes(_ urls: [String]) {
        for url in urls where !queuedRelayDeletes.contains(url) {
            queuedRelayDeletes.append(url)
        }
    }

    @discardableResult
    private func deleteRelayURLs(_ urls: [String], using dataSource: any RelaysViewModelDataSource) async -> Bool {
        guard !isSaving else {
            queueRelayDeletes(urls)
            return false
        }
        let deleteSet = Set(urls)
        let relays = currentRelays
        let next = relays.filter { !deleteSet.contains($0) }
        guard next != relays else { return true }
        return await save(next, using: dataSource)
    }

    private func drainQueuedRelayDeletes(using dataSource: any RelaysViewModelDataSource) async {
        guard !queuedRelayDeletes.isEmpty else { return }
        let urls = queuedRelayDeletes
        queuedRelayDeletes.removeAll()
        let deleted = await deleteRelayURLs(urls, using: dataSource)
        if !deleted {
            queueRelayDeletes(urls)
        }
    }
}
