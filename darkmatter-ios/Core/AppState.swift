import Foundation
import Observation
import MarmotKit

/// Root observable state for the app.
///
/// Holds the `Marmot` handle, the current set of `AccountSummaryFfi`, and
/// which account is active. View models observe this through
/// `@Environment(AppState.self)`. Subscriptions and sends are always
/// performed against `activeAccountRef`.
@Observable
final class AppState {

    enum Phase: Equatable {
        case bootstrapping
        case onboarding
        case ready
        case failed(String)
    }

    /// Where the user is in the global flow. Drives the root router.
    private(set) var phase: Phase = .bootstrapping

    /// All accounts known to marmot-app, refreshed after every account-changing call.
    private(set) var accounts: [AccountSummaryFfi] = []

    /// The account whose chats / messages are currently displayed.
    /// `nil` only between bootstrap and onboarding completion.
    var activeAccountRef: String? {
        didSet {
            if let ref = activeAccountRef {
                UserDefaults.standard.set(ref, forKey: Self.activeAccountKey)
            }
        }
    }

    /// User-editable relay configuration. Persisted in UserDefaults for v1;
    /// future versions may sync this from Nostr kind:10002.
    var defaultRelays: [String] {
        didSet {
            UserDefaults.standard.set(defaultRelays, forKey: Self.relaysKey)
        }
    }

    let client: MarmotClient

    /// Cache of best-known display names keyed by account id hex. Populated
    /// on demand via `displayName(forAccountIdHex:)` and updated when a
    /// refresh succeeds. Read-only from view code.
    private(set) var displayNames: [String: String] = [:]

    /// Most recent transient banner. View code reads this via the
    /// `.toastHost()` modifier on the root view.
    private(set) var activeToast: Toast?
    private var toastDismissTask: Task<Void, Never>?

    /// Tracks in-flight directory fetches so we don't pile up duplicate work.
    private var directoryFetchesInFlight: Set<String> = []

    private static let activeAccountKey = "marmot.activeAccountRef"
    private static let relaysKey = "marmot.defaultRelays"

    init(client: MarmotClient = MarmotClient()) {
        self.client = client
        let storedRelays = UserDefaults.standard.stringArray(forKey: Self.relaysKey)
        self.defaultRelays = storedRelays?.isEmpty == false
            ? (storedRelays ?? MarmotClient.defaultRelays)
            : MarmotClient.defaultRelays
        self.activeAccountRef = UserDefaults.standard.string(forKey: Self.activeAccountKey)
    }

    /// Convenience accessor for the underlying FFI handle.
    var marmot: Marmot { client.marmot }

    // MARK: - Bootstrap

    /// Brings the runtime online and refreshes the account list. Called once
    /// per app launch.
    func bootstrap() async {
        do {
            try await marmot.start()
            try await refreshAccounts()
            if accounts.isEmpty {
                phase = .onboarding
            } else {
                if activeAccountRef == nil
                    || !accounts.contains(where: { $0.label == activeAccountRef }) {
                    activeAccountRef = accounts.first?.label
                }
                phase = .ready
            }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func refreshAccounts() async throws {
        let listed = try await Task.detached { [marmot] in
            try marmot.listAccounts()
        }.value
        accounts = listed
    }

    // MARK: - Identity management

    /// Generate a fresh Nostr identity. On success the new account becomes active.
    @discardableResult
    func createIdentity() async throws -> AccountSummaryFfi {
        let summary = try await marmot.createIdentity(
            defaultRelays: defaultRelays,
            bootstrapRelays: defaultRelays
        )
        try await refreshAccounts()
        activeAccountRef = summary.label
        if phase == .onboarding { phase = .ready }
        return summary
    }

    /// Import an existing identity (nsec for local signing, npub for read-only).
    @discardableResult
    func importIdentity(_ identity: String) async throws -> AccountSummaryFfi {
        let summary = try await marmot.login(
            identity: identity,
            defaultRelays: defaultRelays,
            bootstrapRelays: defaultRelays
        )
        try await refreshAccounts()
        activeAccountRef = summary.label
        if phase == .onboarding { phase = .ready }
        return summary
    }

    var activeAccount: AccountSummaryFfi? {
        guard let ref = activeAccountRef else { return nil }
        return accounts.first { $0.label == ref }
    }

    // MARK: - Display names

    /// Best-effort lookup. Returns the cached name if known, falls back to
    /// the local-account label (when `accountIdHex` matches one of our own
    /// accounts), then the short-hex form. Also schedules a background
    /// refresh on first request for an unknown id so subsequent calls
    /// hydrate naturally.
    @MainActor
    func displayName(forAccountIdHex accountIdHex: String) -> String {
        if let cached = displayNames[accountIdHex] { return cached }
        if let owned = accounts.first(where: { $0.accountIdHex == accountIdHex }) {
            let name = owned.label.isEmpty
                ? IdentityFormatter.short(accountIdHex)
                : owned.label
            displayNames[accountIdHex] = name
            return name
        }
        Task { await self.refreshDisplayName(forAccountIdHex: accountIdHex) }
        return IdentityFormatter.short(accountIdHex)
    }

    @MainActor
    private func refreshDisplayName(forAccountIdHex accountIdHex: String) async {
        guard !directoryFetchesInFlight.contains(accountIdHex) else { return }
        directoryFetchesInFlight.insert(accountIdHex)
        defer { directoryFetchesInFlight.remove(accountIdHex) }

        // First try the cached projection — the runtime may already know it
        // without needing a network hop.
        if let cached = marmot.displayName(accountIdHex: accountIdHex), !cached.isEmpty {
            displayNames[accountIdHex] = cached
            return
        }

        // Otherwise ask the runtime to fetch a fresh directory record.
        do {
            try await marmot.refreshDirectory(
                accountIdHex: accountIdHex,
                bootstrapRelays: defaultRelays
            )
            if let resolved = marmot.displayName(accountIdHex: accountIdHex), !resolved.isEmpty {
                displayNames[accountIdHex] = resolved
            }
        } catch {
            // Silent on directory-fetch failures; the UI will keep showing
            // the short-hex form.
        }
    }

    // MARK: - Toasts

    @MainActor
    func present(_ toast: Toast) {
        toastDismissTask?.cancel()
        activeToast = toast
        let id = toast.id
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(toast.duration * 1_000_000_000))
            guard !Task.isCancelled,
                  let self,
                  self.activeToast?.id == id else { return }
            self.activeToast = nil
        }
    }

    @MainActor
    func dismissToast() {
        toastDismissTask?.cancel()
        activeToast = nil
    }
}
