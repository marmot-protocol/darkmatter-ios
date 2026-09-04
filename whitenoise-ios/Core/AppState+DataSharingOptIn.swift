import Foundation
import MarmotKit

/// The one-time data-sharing choice, offered once per identity right after it
/// first reaches the chat list.
///
/// Both switches it presents — relay telemetry export and audit logging — are
/// runtime-global in Marmot rather than account-scoped, and are written through
/// `PrivacySecuritySettingsViewModel` as they are flipped. So there is nothing to
/// commit when the sheet closes and no third state to keep in step. What lives
/// here is only *when to ask*.
///
/// Asking is two steps because the switches being global makes them part of the
/// decision, and reading them is synchronous FFI that contends with the account
/// setup still running behind a fresh identity. `arm` is the cheap half and runs
/// on the identity path; `resolve` does the read from `RootView`, off the runtime
/// mutation lease that path holds — an inline read there stalls sign-out, which
/// waits for outstanding foreground mutations.
extension AppState {
    /// Mark an identity that just entered the app as a possible candidate, unless
    /// it has been offered before.
    ///
    /// Called from `activateNewIdentity`, the single funnel every *newly entered*
    /// identity passes through (create, import, and consent-gated recovery), once
    /// the phase and active ref are committed. Bootstrap restores an existing
    /// session and reactivation resumes a retained one; neither is a first entry,
    /// and neither goes through here.
    @MainActor
    func armDataSharingOptInIfNeeded(for summary: AccountSummaryFfi) {
        let candidate = DataSharingOptInCandidate(
            accountRef: summary.label,
            accountIdHex: summary.accountIdHex
        )
        guard DataSharingOptInPolicy.candidateAccountIdHex(
            candidate,
            phase: phase,
            activeAccountRef: activeAccountRef,
            alreadyOffered: DataSharingOptInStore.offeredAccountIdHexes(defaults: accountDefaults)
        ) != nil else { return }
        pendingDataSharingOptInCandidate = candidate
    }

    /// Read the global switches and offer the choice if neither is on yet. Driven
    /// by `RootView`, so SwiftUI owns the task's lifetime.
    ///
    /// The candidate is cleared whatever the outcome, including a read that cannot
    /// resolve. Not asking is the recoverable half — Settings → Privacy & Security
    /// carries both switches — while leaving it armed would offer the choice at
    /// some later, arbitrary moment that is no longer this identity's first entry.
    @MainActor
    func resolveDataSharingOptIn() async {
        guard let candidate = pendingDataSharingOptInCandidate else { return }
        let choices = await currentDataSharingChoices()
        pendingDataSharingOptInCandidate = nil

        guard let choices, let accountIdHex = DataSharingOptInPolicy.accountIdHexToOffer(
            candidate,
            phase: phase,
            activeAccountRef: activeAccountRef,
            alreadyOffered: DataSharingOptInStore.offeredAccountIdHexes(defaults: accountDefaults),
            choices: choices
        ) else { return }

        // Recorded when the sheet goes up rather than when it comes down.
        // Dismissal is a valid answer ("leave both off"), and the sheet is only
        // ever reached from a fresh sign-up or sign-in — so a quit with it still
        // open would otherwise mean the identity is asked again on a path it can
        // no longer take, or never asked at all.
        DataSharingOptInStore.markOffered(accountIdHex: accountIdHex, defaults: accountDefaults)
        isDataSharingOptInPresented = true
    }

    /// Close the sheet. Both switches wrote through as they were flipped, so
    /// there is nothing else to do here.
    @MainActor
    func dismissDataSharingOptIn() {
        isDataSharingOptInPresented = false
    }

    /// Drop a wiped identity's record. Only on a destructive wipe — a normal
    /// sign-out retains the account for reactivation, and re-asking a retained
    /// identity would offer a choice it already made.
    @MainActor
    func forgetDataSharingOptIn(accountIdHex: String) {
        DataSharingOptInStore.forget(accountIdHex: accountIdHex, defaults: accountDefaults)
    }

    /// `nil` when either switch cannot be read.
    @MainActor
    private func currentDataSharingChoices() async -> DataSharingChoices? {
        guard let telemetry = try? await relayTelemetrySettings(),
              let audit = try? await auditLogSettings()
        else { return nil }
        return DataSharingChoices(
            telemetryEnabled: telemetry.exportEnabled,
            auditLoggingEnabled: audit.enabled
        )
    }
}
