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

    /// Cache of best-known display names keyed by account id hex. Derived
    /// from `profiles` when available. Read-only from view code.
    private(set) var displayNames: [String: String] = [:]

    /// Cache of full Nostr kind:0 profiles keyed by account id hex. Populated
    /// on demand via `profile(forAccountIdHex:)`. Read-only from view code.
    private(set) var profiles: [String: UserProfileMetadataFfi] = [:]

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

    // MARK: - Profiles & display names

    /// Full Nostr profile for an account id. Returns the cached value
    /// immediately if known; otherwise does a fast synchronous read from the
    /// runtime's directory cache, and on a miss schedules a background relay
    /// fetch so a later call hydrates. `nil` until something is known.
    @MainActor
    @discardableResult
    func profile(forAccountIdHex id: String) -> UserProfileMetadataFfi? {
        if let cached = profiles[id] { return cached }
        if let local = (try? marmot.userProfile(accountIdHex: id)) ?? nil {
            cacheProfile(local, for: id)
            return local
        }
        Task { await refreshProfile(forAccountIdHex: id) }
        return nil
    }

    /// Best-effort display name. Prefers the projected kind:0 display_name /
    /// name, then a local account's label, then short-hex.
    @MainActor
    func displayName(forAccountIdHex id: String) -> String {
        if let p = profile(forAccountIdHex: id), let name = Self.name(from: p) {
            return name
        }
        if let cached = displayNames[id] { return cached }
        if let owned = accounts.first(where: { $0.accountIdHex == id }) {
            return owned.label.isEmpty ? IdentityFormatter.short(id) : owned.label
        }
        return IdentityFormatter.short(id)
    }

    /// Picture URL for an account id, if its profile has one.
    @MainActor
    func avatarURL(forAccountIdHex id: String) -> URL? {
        guard let picture = profile(forAccountIdHex: id)?.picture,
              !picture.isEmpty else { return nil }
        return URL(string: picture)
    }

    /// Store a profile in the cache and derive its display name. Called after
    /// a successful publish so the editor and chrome update immediately.
    @MainActor
    func cacheProfile(_ profile: UserProfileMetadataFfi, for id: String) {
        profiles[id] = profile
        if let name = Self.name(from: profile) {
            displayNames[id] = name
        }
    }

    @MainActor
    private func refreshProfile(forAccountIdHex id: String) async {
        guard !directoryFetchesInFlight.contains(id) else { return }
        directoryFetchesInFlight.insert(id)
        defer { directoryFetchesInFlight.remove(id) }

        if let local = (try? marmot.userProfile(accountIdHex: id)) ?? nil {
            cacheProfile(local, for: id)
            return
        }

        try? await marmot.refreshDirectory(accountIdHex: id, bootstrapRelays: defaultRelays)

        if let fetched = (try? marmot.userProfile(accountIdHex: id)) ?? nil {
            cacheProfile(fetched, for: id)
        } else if let name = marmot.displayName(accountIdHex: id), !name.isEmpty {
            displayNames[id] = name
        }
    }

    private static func name(from profile: UserProfileMetadataFfi) -> String? {
        let candidate = (profile.displayName ?? profile.name)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate, !candidate.isEmpty else { return nil }
        return candidate
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
