import Foundation
import Observation
import MarmotKit

nonisolated enum ForegroundRuntimeWorkGate {
    static func canUseLocalForegroundWork(
        isAppSceneActive: Bool,
        runtimeSuspendedForBackground: Bool,
        isRuntimeSuspending: Bool,
        hasRuntimeClient: Bool
    ) -> Bool {
        isAppSceneActive
            && !runtimeSuspendedForBackground
            && !isRuntimeSuspending
            && hasRuntimeClient
    }

    static func canUseForegroundWork(
        isAppSceneActive: Bool,
        runtimeSuspendedForBackground: Bool,
        isRuntimeSuspending: Bool
    ) -> Bool {
        isAppSceneActive
            && !runtimeSuspendedForBackground
            && !isRuntimeSuspending
    }
}

/// Root observable state for the app.
///
/// Holds the `Marmot` handle, the current set of `AccountSummaryFfi`, and
/// which account is active. View models observe this through
/// `@Environment(AppState.self)`. Subscriptions and sends are always
/// performed against `activeAccountRef`.
@Observable
final class AppState {

    nonisolated enum Phase: Equatable {
        case bootstrapping
        case onboarding
        case ready
        case failed(String)
    }

    typealias ProfileLink = AppProfileLink

    /// Where the user is in the global flow. Drives the root router.
    private(set) var phase: Phase = .bootstrapping

    /// Phases that own a live, started Marmot runtime (its SQLite store open in
    /// the shared App Group container). Both must release that runtime on
    /// background suspension and rebuild it on foreground resume, otherwise the
    /// held file lock risks a `0xdead10cc` watchdog kill (#338). `performBootstrap`
    /// starts the runtime *before* checking for accounts, so `.onboarding` carries
    /// a live runtime exactly like `.ready` does — the suspend/resume machinery
    /// must treat them the same. Maintenance that needs an active account
    /// (notification subscription, push registration) stays gated on `.ready`.
    /// Read by `RuntimeLifecycle` through its back-reference.
    var phaseOwnsLiveRuntime: Bool {
        phase == .ready || phase == .onboarding
    }

    /// Mutator used by `RuntimeLifecycle` (which owns bootstrap/resume) to drive
    /// the router; `phase` stays `private(set)` so feature code can't write it.
    func setPhase(_ newPhase: Phase) {
        phase = newPhase
    }

    /// Account list + active selection. Owned by `AccountStore`; these forwarders
    /// keep the `appState.accounts` / `activeAccountRef` / `activeAccount` call
    /// sites and SwiftUI observation unchanged. AppState still drives the Marmot
    /// account refresh and the identity lifecycle (create / import / sign-out).
    @ObservationIgnored let accountStore = AccountStore()
    var accounts: [AccountSummaryFfi] { accountStore.accounts }

    /// Per-account unread totals (account-switcher badges). Owned by
    /// `AccountUnreadStore`; this read-only forwarder keeps the
    /// `appState.accountUnreadSummariesByAccountId` call sites and SwiftUI
    /// observation of the badges unchanged.
    @ObservationIgnored let accountUnreadStore = AccountUnreadStore()
    var accountUnreadSummariesByAccountId: [String: AccountUnreadFfi] {
        accountUnreadStore.byAccountId
    }

    /// Account/group-scoped unsent composer text. The store owns protected-file
    /// persistence and is shared by conversations and the chat-list projection.
    @ObservationIgnored let conversationDraftStore: ConversationDraftStore

    /// The account whose chats / messages are currently displayed.
    /// `nil` only between bootstrap and onboarding completion. Backed by
    /// `AccountStore` (which persists it to UserDefaults).
    var activeAccountRef: String? {
        get { accountStore.activeAccountRef }
        set { accountStore.activeAccountRef = newValue }
    }

    /// Developer mode: surfaces extra debugging UI (e.g. MLS group internals
    /// on the chat-details screen). Off by default; toggled in Settings.
    var developerMode: Bool {
        didSet {
            UserDefaults.standard.set(developerMode, forKey: Self.developerModeKey)
        }
    }

    /// When developer mode is on, show every MLS/stream event in the
    /// conversation timeline with debug styling (kinds 1200+, reactions, etc.).
    var streamingDebugMode: Bool {
        didSet {
            UserDefaults.standard.set(streamingDebugMode, forKey: Self.streamingDebugModeKey)
        }
    }

    /// Effective streaming-debug flag: requires developer mode.
    var streamingDebugEnabled: Bool {
        developerMode && streamingDebugMode
    }

    /// Blocks screenshots and screen recordings of app content while on
    /// (window-level capture exclusion, applied by `WindowCaptureProtection`).
    /// Off by default; toggled in Settings → Privacy & Security.
    var blockScreenshots: Bool {
        didSet {
            UserDefaults.standard.set(blockScreenshots, forKey: Self.blockScreenshotsKey)
        }
    }

    /// Recently-used reaction emojis, most-recent first. Drives the quick row
    /// in the message actions overlay.
    private(set) var recentReactions: [String]

    static let defaultReactions = ["❤️", "👍", "👎", "😂", "😮", "😢"]

    /// The six emojis to show in the quick-reaction row: recents first,
    /// topped up with defaults.
    var quickReactions: [String] {
        var result = recentReactions
        for emoji in Self.defaultReactions where result.count < 6 {
            if !result.contains(emoji) { result.append(emoji) }
        }
        return Array(result.prefix(6))
    }

    func addRecentReaction(_ emoji: String) {
        var list = recentReactions.filter { $0 != emoji }
        list.insert(emoji, at: 0)
        recentReactions = Array(list.prefix(12))
        UserDefaults.standard.set(recentReactions, forKey: Self.recentReactionsKey)
    }

    /// Runtime-lifecycle ownership: the live `MarmotClient`, the
    /// foreground/suspension gates, the runtime generation, bootstrap, and the
    /// background suspend / foreground resume orchestration. Carved out of
    /// `AppState` (Phase 2); AppState keeps the thin forwarders below so call
    /// sites are unchanged. Wired (`configure(appState:)`) in init.
    @ObservationIgnored let runtimeLifecycle: RuntimeLifecycle

    /// The live FFI runtime. Released (`nil`) while the app is suspended in the
    /// background so its SQLite storage in the shared App Group container is
    /// closed and its file lock freed — otherwise iOS terminates the app at
    /// suspension with `0xdead10cc` ("held a file lock in a shared container").
    /// Rebuilt on foreground in `resumeAfterForegroundActivation`. Owned by
    /// `RuntimeLifecycle`; this computed forwarder keeps the `appState.client`
    /// call sites (and the AppState-internal notification/settings reads)
    /// unchanged. Not observed (it forwards to `RuntimeLifecycle`'s
    /// `@ObservationIgnored client`), matching the original raw-handle semantics.
    var client: MarmotClient? { runtimeLifecycle.client }
    let notifications: AppNotifications
    @ObservationIgnored let notificationCoordinator = NotificationCoordinator()
    let toastState = ToastState()
    let navigation = NavigationState()
    /// Optional local-auth gate and app-switcher privacy shield. UI-only:
    /// runtime suspend/resume stays independent of the lock state.
    let appLock = AppLockController()
    /// Profile projection cache + hydration/refresh queues. `profileRefreshGeneration`
    /// stays on AppState (below) as the observed token; the store reads/bumps it
    /// through its back-reference so SwiftUI observation is unchanged.
    @ObservationIgnored let profileStore = ProfileStore()
    /// True only while `signOut()` is tearing down the departing account. Set
    /// before any of sign-out's `await` suspension points and cleared once the
    /// account is removed and `accounts` refreshed. `scheduleNativePushRegistrationIfEnabled()`
    /// consults this so a system-driven APNS token arriving mid-sign-out cannot
    /// spawn a fresh registration sync that re-`upsertPushRegistration`s the
    /// account whose registration sign-out just cleared (#320, residual of
    /// #7/#111). MainActor-owned; mutated only on the MainActor.
    private var isSigningOut = false
    /// Account refs with an activation already running. Set before signed-out
    /// reactivation awaits so rapid repeated taps cannot start duplicate sign-ins.
    /// MainActor-owned; mutated only by `activateAccount`.
    private var activatingAccountRefs = Set<String>()
    /// Scene-phase flag. Owned here (not on `RuntimeLifecycle`) because many
    /// non-lifecycle gates read it (notification presentation, settings reads,
    /// push scheduling, routing); `RuntimeLifecycle` writes it through its
    /// back-reference from the scene-phase entry points so every gate computes
    /// the same boolean.
    var isAppSceneActive = true
    /// False until any scene-phase entry point runs this launch. A UI-less
    /// background launch (notification action on a terminated app) never
    /// reports a phase while `isAppSceneActive` keeps its optimistic launch
    /// default, so the pair distinguishes "scene is active" from "no scene
    /// ever spoke". Written by `RuntimeLifecycle` alongside `isAppSceneActive`.
    var sceneHasReportedPhase = false
    private(set) var profileRefreshGeneration = 0

    /// Foreground expiration-sweep loop for disappearing messages. Started
    /// with the other `.ready` foreground maintenance and cancelled on
    /// background suspension.
    @ObservationIgnored private let retentionSweeper = MessageRetentionSweeper()
    /// Bumped after a sweep pruned expired records; open conversations observe
    /// it and reload their timeline window when their group is affected.
    private(set) var retentionSweepGeneration = 0
    private(set) var retentionSweepPrunedGroupIds: Set<String> = []

    /// Forwarders to `RuntimeLifecycle`, which owns the runtime-gate state. Keep
    /// the `appState.runtimeSuspendedForBackground` / `isRuntimeWarmingUp` /
    /// `runtimeGeneration` call sites (views, view models, policies, tests) and
    /// SwiftUI observation unchanged.
    var runtimeSuspendedForBackground: Bool { runtimeLifecycle.runtimeSuspendedForBackground }
    var isRuntimeWarmingUp: Bool { runtimeLifecycle.isRuntimeWarmingUp }
    var runtimeGeneration: Int { runtimeLifecycle.runtimeGeneration }
    /// Whether the runtime is mid-suspension. AppState-internal only: the
    /// notification-presentation and settings-read gates that stay on AppState
    /// read it bare.
    private var isRuntimeSuspending: Bool { runtimeLifecycle.isRuntimeSuspendingNow }

    /// Most recent transient banner. View code reads this via the
    /// `.toastHost()` modifier on the root view.
    var activeToast: Toast? { toastState.activeToast }

    /// A profile to present (set by a scanned QR or an opened deep link).
    /// MainView binds a sheet to this.
    var pendingProfile: ProfileLink? { navigation.pendingProfile }

    /// A chat (group id hex) to navigate to once any presenting sheets close —
    /// set right after creating a chat from the composer or a scanned profile.
    /// ChatsListView observes this to push the conversation.
    var pendingChatId: String? { navigation.pendingChatId }
    var pendingChatAccountRef: String? { navigation.pendingChatAccountRef }
    var pendingChatMessageIdHex: String? { navigation.pendingChatMessageIdHex }
    var visibleChat: VisibleChatRoute? { navigation.visibleChat }
    /// Live runtime config when present, cached fallback while suspended.
    /// Forwards to `RuntimeLifecycle` (which holds both the client and the
    /// fallback); do not recompute `TelemetryBuildConfig.current()` here.
    var telemetryBuildConfig: TelemetryBuildConfig { runtimeLifecycle.telemetryBuildConfig }
    var notificationSubscriptionActive: Bool { notificationCoordinator.notificationSubscriptionActive }
    var canRefreshProfiles: Bool { runtimeLifecycle.canRefreshProfiles }
    var canUseRuntimeForLocalForegroundWork: Bool { runtimeLifecycle.canUseRuntimeForLocalForegroundWork }
    var canUseRuntimeForForegroundWork: Bool { runtimeLifecycle.canUseRuntimeForForegroundWork }

    private static let developerModeKey = "marmot.developerMode"
    private static let streamingDebugModeKey = "marmot.streamingDebugMode"
    private static let blockScreenshotsKey = "marmot.blockScreenshots"
    private static let recentReactionsKey = "marmot.recentReactions"
    private static let defaultSuspendedRuntimeTelemetryBuildConfig = TelemetryBuildConfig.current()
    static let agentTextStreamQuicBrokerCandidate = "quic://quic-broker.ipf.dev:4450"
    static let agentTextStreamQuicCandidates = [agentTextStreamQuicBrokerCandidate]

    init(
        client: MarmotClient,
        notifications: AppNotifications,
        conversationDraftStore: ConversationDraftStore? = nil,
        suspendedRuntimeTelemetryBuildConfig: TelemetryBuildConfig = AppState.defaultSuspendedRuntimeTelemetryBuildConfig
    ) {
        self.runtimeLifecycle = RuntimeLifecycle(
            client: client,
            suspendedRuntimeTelemetryBuildConfig: suspendedRuntimeTelemetryBuildConfig
        )
        self.notifications = notifications
        self.conversationDraftStore = conversationDraftStore ?? ConversationDraftStore()
        self.developerMode = UserDefaults.standard.bool(forKey: Self.developerModeKey)
        self.streamingDebugMode = UserDefaults.standard.bool(forKey: Self.streamingDebugModeKey)
        self.blockScreenshots = UserDefaults.standard.bool(forKey: Self.blockScreenshotsKey)
        self.recentReactions = UserDefaults.standard.stringArray(forKey: Self.recentReactionsKey)
            ?? Self.defaultReactions
        self.profileStore.appState = self
        self.runtimeLifecycle.configure(appState: self)
    }

    convenience init(client: MarmotClient) {
        self.init(client: client, notifications: .shared)
    }

    deinit {
        // ProfileStore cancels its own tasks in its deinit.
        // RuntimeLifecycle cancels its own lifecycle tasks in its deinit.
        // NotificationCoordinator cancels its native-push task in its deinit.
    }

    func noteProfileRefreshCompleted() {
        profileRefreshGeneration += 1
    }

    /// Production entry point. Builds a keychain-backed client; if secure
    /// storage or a durable on-disk root can't be initialized the app can't run
    /// safely, so we trap with a clear message rather than fall back to insecure
    /// on-disk keys or a temporary directory iOS will silently purge.
    convenience init() {
        do {
            self.init(client: try MarmotClient())
        } catch {
            // Don't interpolate the error: its description can carry internal
            // Keychain/storage details into crash logs (#21). The type alone is
            // enough to triage which failure mode trapped.
            fatalError(AppState.redactedStorageInitFailureMessage(for: error))
        }
    }

    /// Convenience accessor for the underlying FFI handle.
    ///
    /// AppState-internal seam only: lifecycle/bootstrap, runtime suspend/resume,
    /// and the notification subscription legitimately need the raw handle. Feature
    /// code (views / view-models / stores) must NOT use this — it goes through
    /// `currentMarmotClient()` and the `MarmotClient` wrappers (the one seam),
    /// enforced by `MarmotHandleLockdownTests` (#395).
    ///
    /// Non-optional for call-site ergonomics: the runtime is only released
    /// while the app is suspended, when no UI or view-model code runs. If
    /// something does touch it during the foreground transition (before
    /// `resumeAfterForegroundActivation` restores it), it is rebuilt on demand,
    /// reopening on-disk storage. A rebuild failure is the same unrecoverable
    /// Keychain/storage failure the app traps on at launch.
    var marmot: Marmot {
        if let client { return client.marmot }
        do {
            return try runtimeClient().marmot
        } catch {
            // See init(): keep internal Keychain/storage error details out of
            // crash logs (#21); the error type is enough to triage.
            fatalError(AppState.redactedRuntimeRebuildFailureMessage(for: error))
        }
    }

    // Redacted crash messages for the unrecoverable Keychain/storage init and
    // rebuild traps. Surface only the error type, never its description, so
    // internal Keychain/storage details can't leak into crash logs (#21).
    static func redactedStorageInitFailureMessage(for error: Error) -> String {
        "Failed to initialize durable Marmot storage (\(type(of: error)))"
    }

    static func redactedRuntimeRebuildFailureMessage(for error: Error) -> String {
        "Failed to rebuild Keychain-backed Marmot runtime (\(type(of: error)))"
    }

    func currentMarmotClient() throws -> MarmotClient {
        try runtimeClient()
    }

    private func runtimeClient() throws -> MarmotClient {
        try runtimeLifecycle.runtimeClient()
    }

    // MARK: - Bootstrap

    /// Brings the runtime online and refreshes the account list. Called once
    /// per app launch. Owned by `RuntimeLifecycle`; this forwarder keeps the
    /// `appState.bootstrap()` scene-task call site unchanged.
    @MainActor
    func bootstrap() async {
        await runtimeLifecycle.bootstrap()
    }

    @MainActor
    private func completeOnboardingAfterIdentityActivation(scheduleNativePushRegistration: Bool = true) {
        guard phase == .onboarding else { return }
        phase = .ready
        startReadyForegroundMaintenance(scheduleNativePushRegistration: scheduleNativePushRegistration)
    }

    /// Signing out of the last signed-in account stops the notification
    /// subscription and retention sweeper but keeps the `.ready` shell alive
    /// for reactivation. Activating an account from that shell must restart
    /// both loops; ordinary account switches never stopped the subscription,
    /// so the liveness guard keeps this a no-op there.
    @MainActor
    private func restartReadyForegroundMaintenanceIfStopped() {
        guard phase == .ready, !notificationCoordinator.notificationSubscriptionActive else { return }
        startReadyForegroundMaintenance(scheduleNativePushRegistration: false)
    }

    /// Internal (not `private`) so `RuntimeLifecycle.performBootstrap` can hand
    /// back the account-scoped maintenance once the runtime is ready.
    @MainActor
    func startReadyForegroundMaintenance(scheduleNativePushRegistration: Bool = true) {
        notificationCoordinator.startReadyForegroundMaintenance(
            host: self,
            scheduleNativePushRegistration: scheduleNativePushRegistration
        )
        startRetentionSweeps()
    }

    /// Internal (not `private`) so the `RuntimeLifecycle` resume path can
    /// restart the sweep loop once a `.ready` runtime is back online.
    @MainActor
    func startRetentionSweeps() {
        retentionSweeper.start(appState: self)
    }

    /// Awaited drain used by `RuntimeLifecycle.cancelForegroundMaintenance` so
    /// no sweep FFI call is in flight when suspension releases the runtime.
    func cancelRetentionSweeps() async {
        await retentionSweeper.cancel()
    }

    @MainActor
    func noteRetentionSweepCompleted(prunedGroupIds: Set<String>) {
        retentionSweepPrunedGroupIds = prunedGroupIds
        retentionSweepGeneration += 1
    }

    /// Internal (not `private`) so the `RuntimeLifecycle` resume path can start
    /// the subscription once a `.ready` runtime is back online.
    @MainActor
    func startNotificationSubscription() {
        notificationCoordinator.startNotificationSubscription(host: self)
    }

    /// Internal (not `private`) so `RuntimeLifecycle` can stop the subscription
    /// from its suspend and startup-failure-release paths.
    func stopNotificationSubscription() {
        notificationCoordinator.stopNotificationSubscription()
    }

    @MainActor
    func reportNotificationSubscriptionError(_ error: Error) {
        notificationCoordinator.reportNotificationSubscriptionError(error, host: self)
    }

    @MainActor
    func noteNotificationSubscriptionDelivery() {
        notificationCoordinator.noteNotificationSubscriptionDelivery()
    }

    /// Returns the already-live foreground runtime for settings reads, or nil
    /// while the app is inactive/suspending/suspended. Settings reload tasks can
    /// resume during the background transition; using this helper avoids the
    /// rebuilding `marmot` / `runtimeClient()` accessors so they cannot re-open
    /// the App Group SQLite store after suspension deliberately released it.
    private func foregroundSettingsReadClient() -> MarmotClient? {
        let liveClient = client
        guard SettingsReadRuntimeGate.canRead(
            isTaskCancelled: Task.isCancelled,
            isAppSceneActive: isAppSceneActive,
            runtimeSuspendedForBackground: runtimeSuspendedForBackground,
            isRuntimeSuspending: isRuntimeSuspending,
            hasRuntimeClient: liveClient != nil
        ), let liveClient
        else { return nil }
        return liveClient
    }

    // MARK: - Notifications

    func notificationSettings(for accountRef: String) async -> NotificationSettingsFfi? {
        await notificationCoordinator.notificationSettings(for: accountRef, host: self)
    }

    func pushRegistration(for accountRef: String) async -> PushRegistrationFfi? {
        await notificationCoordinator.pushRegistration(for: accountRef, host: self)
    }

    @discardableResult
    func setLocalNotificationsEnabled(_ enabled: Bool) async throws -> NotificationSettingsFfi {
        try await notificationCoordinator.setLocalNotificationsEnabled(enabled, host: self)
    }

    @discardableResult
    func setNativePushEnabled(_ enabled: Bool) async throws -> NotificationSettingsFfi {
        try await notificationCoordinator.setNativePushEnabled(enabled, host: self)
    }

    private func enableNotificationsByDefault(for accountRef: String) async {
        await notificationCoordinator.enableNotificationsByDefault(for: accountRef, host: self)
    }

    /// Switches the active account, signing it back in first when it was
    /// locally signed out without wiping.
    @MainActor
    func activateAccount(_ accountRef: String) async {
        guard accountRef != activeAccountRef else { return }
        guard let account = accounts.first(where: { $0.label == accountRef }) else { return }
        guard activatingAccountRefs.insert(accountRef).inserted else { return }
        defer { activatingAccountRefs.remove(accountRef) }

        if account.signedOut {
            do {
                _ = try await marmot.signInAccount(accountRef: accountRef)
                try await refreshAccounts()
            } catch {
                present(.error(L10n.string("Couldn't sign in"), message: error.localizedDescription))
                return
            }
        }

        activeAccountRef = accountRef
        restartReadyForegroundMaintenanceIfStopped()
        scheduleNativePushRegistrationIfEnabled()
    }

    /// Set after a destructive Sign Out & Wipe finished with best-effort
    /// failures, so the partial-failure report survives the account teardown:
    /// routing to onboarding (last account) or switching accounts pops the
    /// screen that started the wipe. Hosted by `RootView`. Observed by SwiftUI.
    var pendingWipeReport: WipeReport?

    /// Non-destructively signs out of the active account: clears its native
    /// push registration, deactivates it in Marmot, and switches to the next
    /// signed-in local account. The account row, keys, encrypted store, media,
    /// and drafts stay on device so the Profiles screen can sign it back in.
    ///
    /// Push cleanup is best-effort — a transient marmot error here must not
    /// block the user from signing out.
    @MainActor
    func signOut() async {
        guard let signingOut = activeAccountRef else { return }
        let signingOutAccountIdHex = accounts
            .first(where: { $0.label == signingOut })?
            .accountIdHex
        // Block any APNS-token-driven reschedule for the duration of the
        // teardown. `recordDeviceToken` (MainActor) can land on any of the
        // `await` suspension points below and call
        // `scheduleNativePushRegistrationIfEnabled()`; without this guard that
        // fresh task would re-`upsertPushRegistration` the departing account
        // (still on disk with native push enabled until `setNativePushEnabled`
        // commits, and still in the in-memory `accounts` list until
        // `refreshAccounts`), resurrecting a server-side registration for a
        // signed-out account (#320, residual of #7/#111). The `defer` clears
        // the flag on every exit path, including the early wipe failure return
        // below.
        isSigningOut = true
        defer { isSigningOut = false }
        let nativePushWasEnabled = (
            try? await runtimeClient()
                .notificationSettings(accountRef: signingOut)
                .nativePushEnabled
        ) ?? false
        await notificationCoordinator.cancelNativePushRegistrationTask()
        try? await marmot.clearPushRegistration(accountRef: signingOut)
        _ = try? await marmot.setNativePushEnabled(accountRef: signingOut, enabled: false)

        do {
            let outcome = try await currentMarmotClient().signOut(accountRef: signingOut)
            guard outcome.localCleanup.completed else {
                let message = outcome.localCleanup.reason
                    ?? L10n.string("Local account cleanup did not finish.")
                await restoreNativePushAfterFailedSignOut(
                    accountRef: signingOut,
                    wasEnabled: nativePushWasEnabled
                )
                present(.error(L10n.string("Couldn't sign out"), message: message))
                return
            }
        } catch {
            await restoreNativePushAfterFailedSignOut(
                accountRef: signingOut,
                wasEnabled: nativePushWasEnabled
            )
            present(.error(L10n.string("Couldn't sign out"), message: error.localizedDescription))
            return
        }

        await completeSignOut(
            removedRef: signingOut,
            removedAccountIdHex: signingOutAccountIdHex,
            destructive: false
        )
    }

    /// App-state cleanup shared by normal sign-out and destructive wipe. A
    /// normal sign-out keeps account-scoped local state and leaves a signed-out
    /// row available for reactivation; a wipe removes its drafts/projections
    /// and may return the app to onboarding when no accounts remain.
    @MainActor
    private func completeSignOut(
        removedRef: String,
        removedAccountIdHex: String?,
        destructive: Bool
    ) async {
        if destructive {
            conversationDraftStore.removeDrafts(accountRef: removedRef)
            await conversationDraftStore.flush()

            // Drop the wiped account's private contact nicknames so they don't
            // outlive the identity on this device. Only on a destructive wipe —
            // a normal sign-out retains the account (and its local state,
            // including nicknames) for reactivation.
            if let removedAccountIdHex {
                profileStore.clearContactNicknames(ownerAccountIdHex: removedAccountIdHex)
            }
        }

        do {
            try await refreshAccounts()
        } catch {
            if destructive {
                accountStore.accounts.removeAll { $0.label == removedRef }
            }
            accountUnreadStore.pruneToCurrentAccounts(accounts)
            present(.error(L10n.string("Couldn't refresh accounts"), message: error.localizedDescription))
        }

        // The departing account is now removed from disk and excluded from the
        // in-memory `accounts` list, so it can no longer be re-registered. Clear
        // the guard before routing so a legitimate reschedule for the *new*
        // active account below is not suppressed (the trailing `defer` then
        // becomes a no-op redo).
        isSigningOut = false
        activeAccountRef = accounts.first { account in
            account.label != removedRef && !account.signedOut
        }?.label
        if accounts.isEmpty {
            // Last account signed out: tear the profile-projection state back
            // down to empty so cached peer data (#366), the per-account version
            // map (#353), and their sibling queues do not survive a full sign-out
            // into onboarding. `cancelProfileFetchQueue()` cancels in-flight work
            // and clears the sibling queues but deliberately preserves the
            // monotonic version map (see its comment). The version-map wipe is the
            // ABA barrier for any suspended profile reload: when it resumes, the
            // stale token check fails before it can re-bump the gone account id or
            // apply a projection back into the cache. This reclaims the accumulated
            // entries.
            cancelProfileFetchQueue()
            profileStore.clearForSignOut()
            stopNotificationSubscription()
            retentionSweeper.cancelWithoutAwaiting()
            phase = .onboarding
        } else if activeAccountRef != nil {
            if destructive, let removedAccountIdHex {
                profileStore.clearForAccountRemoval(accountIdHex: removedAccountIdHex)
            }
            scheduleNativePushRegistrationIfEnabled()
        } else {
            // Every retained account is signed out. Keep the main shell alive
            // so Settings → Profiles can reactivate one; stop account-bound
            // foreground maintenance until that happens.
            stopNotificationSubscription()
            retentionSweeper.cancelWithoutAwaiting()
            phase = .ready
        }
    }

    /// Destructive "Sign Out & Wipe" of the active account. Drives the engine's
    /// `signOutAndWipe` (leave MLS groups, delete relay KeyPackages, wipe the
    /// local store, keys, and media) then runs the same post-sign-out cleanup
    /// the normal sign-out does. Native push is cleared per the existing
    /// sign-out rules before the wipe; a total FFI failure rolls push back and
    /// toasts. A finished wipe with best-effort failures surfaces a `WipeReport`
    /// (what remains) rather than aborting — the local removal proceeds either
    /// way, mirroring the Android outcome semantics.
    ///
    /// Suspension safety: the destructive teardown only begins with a live
    /// foreground runtime (scene active, not suspended/suspending, client
    /// present) so it can never reopen the App Group SQLite store after
    /// suspension released it (`0xdead10cc`). This is the union of the guarded
    /// settings-read gate and the `.ready` gate the audit-log delete uses.
    @MainActor
    func signOutAndWipeActiveAccount() async {
        guard let wipingRef = activeAccountRef else { return }
        guard DestructiveWipeGate.canBegin(
            isReady: phase == .ready,
            isAppSceneActive: isAppSceneActive,
            runtimeSuspendedForBackground: runtimeSuspendedForBackground,
            isRuntimeSuspending: isRuntimeSuspending,
            hasRuntimeClient: client != nil
        ) else {
            present(.error(L10n.string("Couldn't wipe profile")))
            return
        }
        let wipingAccountIdHex = accounts
            .first(where: { $0.label == wipingRef })?
            .accountIdHex

        // Same #320 guard the normal sign-out uses: block any APNS-token-driven
        // push reschedule for the whole teardown; cleared before routing so a
        // reschedule for the *new* active account is not suppressed.
        isSigningOut = true
        defer { isSigningOut = false }
        let nativePushWasEnabled = (
            try? await runtimeClient()
                .notificationSettings(accountRef: wipingRef)
                .nativePushEnabled
        ) ?? false
        // Sign-out push rule: cancel and await the in-flight native-push
        // registration sync before clearing the departing account's registration.
        await notificationCoordinator.cancelNativePushRegistrationTask()
        try? await marmot.clearPushRegistration(accountRef: wipingRef)
        _ = try? await marmot.setNativePushEnabled(accountRef: wipingRef, enabled: false)

        let outcome: WipeOutcomeFfi
        do {
            outcome = try await currentMarmotClient().signOutAndWipe(accountRef: wipingRef)
        } catch {
            // Total FFI failure: nothing was wiped. Roll native push back and toast.
            await restoreNativePushAfterFailedSignOut(
                accountRef: wipingRef,
                wasEnabled: nativePushWasEnabled
            )
            present(.error(L10n.string("Couldn't wipe profile"), message: error.localizedDescription))
            return
        }

        // The wipe returned: the account ref is invalid now. Do the same local
        // removal + routing the normal sign-out does — regardless of per-stage
        // best-effort failures — then surface a report only when something remains.
        await completeSignOut(
            removedRef: wipingRef,
            removedAccountIdHex: wipingAccountIdHex,
            destructive: true
        )

        let report = WipeReportProjection.report(from: outcome)
        if report.clean {
            present(.success(L10n.string("Profile wiped from this device")))
        } else {
            pendingWipeReport = report
        }
    }

    @MainActor
    private func restoreNativePushAfterFailedSignOut(
        accountRef: String,
        wasEnabled: Bool
    ) async {
        guard wasEnabled else { return }
        _ = try? await marmot.setNativePushEnabled(accountRef: accountRef, enabled: true)
        isSigningOut = false
        scheduleNativePushRegistrationIfEnabled()
    }

    @discardableResult
    func syncNativePushRegistration(accountRef: String) async throws -> PushRegistrationFfi {
        try await notificationCoordinator.syncNativePushRegistration(accountRef: accountRef, host: self)
    }

    func syncNativePushRegistrationIfEnabled() async {
        await notificationCoordinator.syncNativePushRegistrationIfEnabled(host: self)
    }

    func scheduleNativePushRegistrationIfEnabled() {
        notificationCoordinator.scheduleNativePushRegistrationIfEnabled(host: self)
    }

    /// Cancels and drains the native-push registration task. The task itself is
    /// owned by `NotificationCoordinator` (master #401); this internal wrapper
    /// lets `RuntimeLifecycle.releaseRuntimeAfterStartupFailure` /
    /// `cancelForegroundMaintenance` drain it without reaching into the
    /// coordinator directly. Also called by `signOut()`.
    func cancelNativePushRegistrationTask() async {
        await notificationCoordinator.cancelNativePushRegistrationTask()
    }

    /// Synchronously cancels the in-flight native-push registration task without
    /// awaiting it. Wraps `NotificationCoordinator` for the scene-phase entry
    /// points in `RuntimeLifecycle` (`setAppSceneActive`,
    /// `startRuntimeSuspension`); the drain-and-await happens later in
    /// `cancelForegroundMaintenance`.
    func cancelNativePushRegistrationTaskSync() {
        notificationCoordinator.cancelNativePushRegistrationTaskWithoutAwaiting()
    }

    func relayTelemetrySettings() async throws -> RelayTelemetrySettingsFfi? {
        guard let client = foregroundSettingsReadClient() else { return nil }
        return try await client.relayTelemetrySettings()
    }

    func privacySecuritySettingsProjection() async throws -> PrivacySecuritySettingsProjection? {
        guard let client = foregroundSettingsReadClient() else { return nil }
        return try await client.privacySecuritySettingsProjection()
    }

    /// Parses markdown off the MainActor for the send path's optimistic record.
    /// Falls back to an empty document if the runtime can't be resolved (e.g.
    /// during a suspend/resume window); the timeline subscription will replace
    /// the optimistic record with the confirmed, fully-parsed one (#226).
    func parseMarkdown(text: String) async -> MarkdownDocumentFfi {
        guard let client = foregroundSettingsReadClient() else { return .emptyDocument }
        return await client.parseMarkdown(text: text)
    }

    @MainActor
    @discardableResult
    func setRelayTelemetryExportEnabled(_ enabled: Bool) async throws -> RelayTelemetrySettingsFfi {
        if enabled && !telemetryBuildConfig.telemetryCredentialsAvailable {
            throw TelemetrySettingsActionError.telemetryNotConfigured
        }
        let client = try runtimeClient()
        if enabled {
            try await client.configureTelemetryRuntime()
        }
        let current = try await client.relayTelemetrySettings()
        return try await client.marmot.setRelayTelemetrySettings(
            settings: RelayTelemetrySettingsFfi(
                exportEnabled: enabled,
                exportIntervalSeconds: current.exportIntervalSeconds
            )
        )
    }

    func auditLogSettings() async throws -> AuditLogSettingsFfi? {
        guard let client = foregroundSettingsReadClient() else { return nil }
        return try await client.auditLogSettings()
    }

    @MainActor
    @discardableResult
    func setAuditLogEnabled(_ enabled: Bool) async throws -> AuditLogSettingsFfi {
        try await marmot.setAuditLogSettings(settings: AuditLogSettingsFfi(enabled: enabled,  dataMode: .fullData))
    }

    func auditLogFiles() async throws -> [AuditLogFileFfi]? {
        guard let client = foregroundSettingsReadClient() else { return nil }
        return try await client.auditLogFiles()
    }

    func auditLogFileRows() async throws -> [AuditFileRow]? {
        guard let client = foregroundSettingsReadClient() else { return nil }
        return try await client.auditFileRows()
    }

    @MainActor
    func deleteAllAuditLogFiles() async throws {
        // Fail loudly when the runtime isn't ready (e.g. a suspend window). A
        // silent success-shaped return would let the UI clear the list and play
        // a success haptic while nothing was deleted, then the files reappear on
        // the next foreground reload — a false confirmation for a privacy action.
        guard phase == .ready else { throw AuditLogActionError.runtimeNotReady }
        let client = try runtimeClient()
        let files = try await client.auditLogFiles()
        for file in files {
            _ = try await client.marmot.deleteAuditLogFile(path: file.path)
        }
    }

    /// Foreground relay catch-up. Delegates to `NotificationCoordinator` (master
    /// #401), which owns the catch-up gate/in-flight flag. Internal (not
    /// `private`) so `RuntimeLifecycle`'s resume path can sequence it without
    /// duplicating the catch-up state.
    func catchUpAfterForegroundActivation() async {
        await notificationCoordinator.catchUpAfterForegroundActivation(host: self)
    }

    /// Scene-phase entry points. Owned by `RuntimeLifecycle`; these forwarders
    /// keep the `whitenoise_iosApp.swift` scene wiring and the test call sites
    /// (`appState.setAppSceneActive`/`startForegroundActivation`/
    /// `startRuntimeSuspension`) unchanged.
    func setAppSceneActive(_ active: Bool) {
        runtimeLifecycle.setAppSceneActive(active)
    }

    @discardableResult
    func startForegroundActivation() -> Task<Void, Never> {
        runtimeLifecycle.startForegroundActivation()
    }

    @discardableResult
    func startRuntimeSuspension() -> Task<Void, Never> {
        let runtimeSuspensionTask = runtimeLifecycle.startRuntimeSuspension()
        let conversationDraftStore = conversationDraftStore
        return Task { @MainActor in
            await conversationDraftStore.flush()
            await runtimeSuspensionTask.value
        }
    }

    /// Cancels the AppState-side foreground maintenance for the lifecycle
    /// suspension path: it cancels (without awaiting) the
    /// `NotificationCoordinator`-owned native-push registration task and the
    /// profile fetch queue, returning the now-cancelled profile task for
    /// `RuntimeLifecycle.cancelForegroundMaintenance` to drain. The native-push
    /// drain itself goes back through `cancelNativePushRegistrationTask()` so the
    /// task stays owned by `NotificationCoordinator` (master #401).
    @MainActor
    func beginForegroundMaintenanceCancellation() -> Task<Void, Never>? {
        notificationCoordinator.cancelNativePushRegistrationTaskWithoutAwaiting()
        retentionSweeper.cancelWithoutAwaiting()
        return cancelProfileFetchQueue()
    }

    static func nativePushEnabledAccountRefs(
        accountRefs: [String],
        runtimeClient: () throws -> MarmotClient
    ) async -> [String] {
        await NotificationCoordinator.nativePushEnabledAccountRefs(
            accountRefs: accountRefs,
            runtimeClient: runtimeClient
        )
    }

    /// Internal (not `private`) so `RuntimeLifecycle.performBootstrap` can drive
    /// the account refresh once the runtime is online. The account refresh
    /// itself stays on AppState (it is account/profile maintenance, not
    /// lifecycle).
    @MainActor
    func refreshAccounts() async throws {
        accountStore.accounts = try await runtimeClient().listAccounts()
        await refreshAccountUnreadSummaries()
        updateProfileProjectionLocalAccountLabels()
        warmLocalAccountProfileProjections()
    }

    @ObservationIgnored private var unreadSummaryRefreshGeneration = 0
    /// Tracked so suspension can drain an in-flight badge refresh before the
    /// runtime shuts down; an escaping task could otherwise hold the FFI
    /// handle mid-`accountUnreadSummary()` while `shutdown()` runs.
    @ObservationIgnored private var unreadSummaryRefreshTask: Task<Void, Never>?

    /// Fire-and-forget wrapper for foreground resume — background reads and
    /// notification actions can move the read cursor while the cached summary
    /// goes stale.
    @MainActor
    func scheduleAccountUnreadSummaryRefresh() {
        let previous = unreadSummaryRefreshTask
        unreadSummaryRefreshTask = Task { @MainActor [weak self] in
            await previous?.value
            await self?.refreshAccountUnreadSummaries()
        }
    }

    /// Awaited by `RuntimeLifecycle.cancelForegroundMaintenance` so no badge
    /// refresh FFI read is in flight when suspension releases the runtime.
    @MainActor
    func drainUnreadSummaryRefresh() async {
        let task = unreadSummaryRefreshTask
        unreadSummaryRefreshTask = nil
        await task?.value
    }

    /// Fetches the durable unread aggregate (client access is AppState's domain)
    /// and feeds it to the store; on failure prunes stale entries. Concurrent
    /// refreshes can complete out of order — only the newest may commit, so an
    /// older fetch can't overwrite fresher badge counts.
    @MainActor
    func refreshAccountUnreadSummaries(using leasedClient: MarmotClient? = nil) async {
        guard !accounts.isEmpty else {
            accountUnreadStore.refreshed(from: [], accounts: [])
            return
        }
        // A badge refresh has no foreground UI to update while the durable
        // runtime is down, so it must never resurrect it: rebuilding a suspended
        // runtime in the background would strand a durable `.advance` runtime
        // holding the App Group SQLite lock (`0xdead10cc`). Foreground callers
        // have a live `client`; a notification action passes its leased runtime.
        // With neither, degrade to a no-op rather than reach the rebuilding
        // `runtimeClient()` accessor.
        guard let summaryClient = leasedClient ?? client else { return }
        unreadSummaryRefreshGeneration += 1
        let generation = unreadSummaryRefreshGeneration
        do {
            let summaries = try await summaryClient.accountUnreadSummary()
            guard generation == unreadSummaryRefreshGeneration else { return }
            accountUnreadStore.refreshed(from: summaries, accounts: accounts)
        } catch {
            guard generation == unreadSummaryRefreshGeneration else { return }
            accountUnreadStore.pruneToCurrentAccounts(accounts)
        }
    }

    @MainActor
    func accountUnreadSummary(forAccountIdHex accountIdHex: String) -> AccountUnreadFfi? {
        accountUnreadStore.summary(forAccountIdHex: accountIdHex)
    }

    @MainActor
    func updateAccountUnreadSummary(
        accountIdHex: String,
        chatListRows: [ChatListRowFfi]
    ) {
        accountUnreadStore.update(accountIdHex: accountIdHex, chatListRows: chatListRows, accounts: accounts)
    }

    // MARK: - Identity management

    /// Generate a fresh Nostr identity. On success the new account becomes active.
    /// Marmot owns the default profile pseudonym pool; iOS must not mirror it.
    @MainActor
    @discardableResult
    func createIdentity() async throws -> AccountSummaryFfi {
        let relays = MarmotClient.seedRelays
        let summary = try await marmot.createIdentity(
            defaultRelays: relays,
            bootstrapRelays: relays
        )
        await activateNewIdentity(summary)
        return summary
    }

    /// Import an existing local-signing identity (nsec).
    @MainActor
    @discardableResult
    func importIdentity(_ identity: String) async throws -> AccountSummaryFfi {
        let relays = MarmotClient.seedRelays
        let summary = try await marmot.login(
            identity: identity,
            defaultRelays: relays,
            bootstrapRelays: relays
        )
        await activateNewIdentity(summary)
        return summary
    }

    @MainActor
    private func activateNewIdentity(_ summary: AccountSummaryFfi) async {
        cacheActivatedAccountSummaryIfNeeded(summary)
        do {
            try await refreshAccounts()
        } catch {
            updateProfileProjectionLocalAccountLabels()
            warmProfileProjection(forAccountIdHex: summary.accountIdHex)
        }

        activeAccountRef = summary.label
        completeOnboardingAfterIdentityActivation(scheduleNativePushRegistration: false)
        // A new identity can also be created from the `.ready` shell left by a
        // sign-out of every account; the onboarding completion above is a no-op
        // there, so the stopped maintenance loops need the same restart as
        // `activateAccount`.
        restartReadyForegroundMaintenanceIfStopped()
        await enableNotificationsByDefault(for: summary.label)
        scheduleNativePushRegistrationIfEnabled()
    }

    @MainActor
    private func cacheActivatedAccountSummaryIfNeeded(_ summary: AccountSummaryFfi) {
        guard !accountStore.accounts.contains(where: { $0.label == summary.label }) else { return }
        accountStore.accounts.append(summary)
    }

    var activeAccount: AccountSummaryFfi? { accountStore.activeAccount }

    /// Reads the published account relay-list projection off the MainActor.
    /// `Marmot.accountRelayLists` is synchronous FFI backed by local storage, so
    /// MainActor-bound callers (profile publish / profile refresh) must await the
    /// `MarmotClient.accountRelayLists` wrapper rather than calling the generated
    /// binding inline (#318). Mirrors the #247/#317 offload approach.
    func relayLists(for accountRef: String) async -> AccountRelayListsFfi? {
        try? await currentMarmotClient().accountRelayLists(accountRef: accountRef)
    }

    func relayPublishRelays(for accountRef: String) async -> [String] {
        guard let lists = await relayLists(for: accountRef) else { return MarmotClient.seedRelays }
        let relays = RelaySettings.editableRelays(from: lists)
        return relays.isEmpty ? MarmotClient.seedRelays : relays
    }

    func relayBootstrapRelays(for accountRef: String) async -> [String] {
        guard let lists = await relayLists(for: accountRef) else { return MarmotClient.seedRelays }
        return RelaySettings.bootstrapRelays(from: lists)
    }

    func revealNsec(accountRef: String) async throws -> String {
        try await currentMarmotClient().revealNsec(accountRef: accountRef)
    }

    func exportEncryptedSecretKey(accountRef: String, passphrase: String) async throws -> String {
        try await currentMarmotClient().exportEncryptedSecretKey(
            accountRef: accountRef,
            passphrase: passphrase
        )
    }

    @discardableResult
    func startAgentTextStream(
        accountRef: String,
        groupIdHex: String,
        streamIdHex: String? = nil
    ) async throws -> AgentStreamStartFfi {
        try await marmot.startAgentTextStream(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            streamIdHex: streamIdHex,
            quicCandidates: Self.agentTextStreamQuicCandidates
        )
    }

    #if DEBUG
    /// Drives the suspend/resume lifecycle tasks to quiescence so tests can
    /// drive the real scene-phase entry points (`startRuntimeSuspension` /
    /// `startForegroundActivation`) and then await the terminal state. Forwards
    /// to `RuntimeLifecycle` (which owns the suspension/foreground tasks) and
    /// drains the AppState-owned native-push task last.
    @MainActor
    func drainRuntimeLifecycleTasksForTesting() async {
        await runtimeLifecycle.drainRuntimeLifecycleTasksForTesting()
    }

    /// Drains the in-flight native-push registration task so
    /// `RuntimeLifecycle.drainRuntimeLifecycleTasksForTesting` can flush the
    /// `NotificationCoordinator`-owned task as the last step of the lifecycle
    /// chain.
    @MainActor
    func nativePushRegistrationTaskValueForTesting() async {
        await notificationCoordinator.drainNativePushRegistrationTaskForTesting()
    }

    /// Exposes the sign-out teardown guard (#320) so tests can assert it is
    /// raised only during `signOut()` and cleared before the function returns
    /// (so a legitimate post-sign-out reschedule is not suppressed).
    @MainActor
    var isSigningOutForTesting: Bool { isSigningOut }

    var retentionSweeperIsActiveForTesting: Bool { retentionSweeper.isSweeping }

    var hasPendingUnreadSummaryRefreshForTesting: Bool { unreadSummaryRefreshTask != nil }
    #endif
}

extension AppState: NotificationCoordinatorHost {
    func configureNotifications() {
        notifications.configure(appState: self)
    }

    var isRuntimeSuspendingForNotificationCoordinator: Bool { isRuntimeSuspending }
    var isSigningOutForNotificationCoordinator: Bool { isSigningOut }
}
