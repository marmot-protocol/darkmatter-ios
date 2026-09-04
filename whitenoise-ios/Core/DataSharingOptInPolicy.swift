import Foundation

/// The identity that just entered the app, as the data-sharing offer sees it.
/// Both fields come from the same `AccountSummaryFfi`: the ref is what an
/// account switch would move, the id hex is what the offer is recorded against.
nonisolated struct DataSharingOptInCandidate: Equatable {
    let accountRef: String
    let accountIdHex: String
}

/// The two data-sharing switches as they currently stand.
///
/// Runtime-global in Marmot, not per account: `relayTelemetrySettings` and
/// `auditLogSettings` — and both setters — take no account ref, so one
/// identity's answer is every identity's answer.
nonisolated struct DataSharingChoices: Equatable {
    let telemetryEnabled: Bool
    let auditLoggingEnabled: Bool

    /// Nothing has been turned on yet, so there is still something to opt into.
    var isUnanswered: Bool {
        !telemetryEnabled && !auditLoggingEnabled
    }
}

/// When to offer the one-time data-sharing choice. Pure so the guard chain is
/// testable without a runtime: `AppState` supplies the phase, the live active
/// ref, the recorded set, and the current switches, and gets back the id hex to
/// ask (and record) or `nil`.
nonisolated enum DataSharingOptInPolicy {
    /// The full decision. Evaluated after the switches have been read, so every
    /// guard below is re-checked against state that may have moved during it.
    static func accountIdHexToOffer(
        _ candidate: DataSharingOptInCandidate,
        phase: AppState.Phase,
        activeAccountRef: String?,
        alreadyOffered: Set<String>,
        choices: DataSharingChoices
    ) -> String? {
        guard let accountIdHex = candidateAccountIdHex(
            candidate,
            phase: phase,
            activeAccountRef: activeAccountRef,
            alreadyOffered: alreadyOffered
        ) else { return nil }

        // The switches are global, so a second identity inherits whatever the
        // first one answered. Offering an opt-in over an already-enabled switch
        // would present a settled decision as a fresh choice — and closing the
        // sheet, which reads as declining, would leave it enabled.
        guard choices.isUnanswered else { return nil }
        return accountIdHex
    }

    /// The runtime-free half, so the identity lifecycle can discard the common
    /// case without paying for a settings read it does not need.
    static func candidateAccountIdHex(
        _ candidate: DataSharingOptInCandidate,
        phase: AppState.Phase,
        activeAccountRef: String?,
        alreadyOffered: Set<String>
    ) -> String? {
        // The offer sits over the main shell, so an identity still in onboarding
        // (or one whose bootstrap failed) has not reached the moment being asked
        // about.
        guard phase == .ready else { return nil }

        // An identity with no hex cannot be recorded as asked, so asking it would
        // repeat on every entry.
        guard let accountIdHex = DataSharingOptInStore.normalized(candidate.accountIdHex) else { return nil }

        // Activation goes through awaited work, and a switch from Settings commits
        // `activeAccountRef` synchronously — so a switch landing in that window
        // leaves a *different* identity active by the time this runs. Asking
        // whoever is active now would spend that account's one lifetime offer on a
        // moment that is not its first entry, and the identity that just signed in
        // would never be asked at all.
        //
        // Dropped rather than deferred: the offer is "right after this identity
        // first reaches the chat list", and once the user has moved on that moment
        // has passed. Not asking is the recoverable half — Settings carries both
        // switches — while a wrongly-spent record is not.
        guard activeAccountRef == candidate.accountRef else { return nil }

        guard !alreadyOffered.contains(accountIdHex) else { return nil }
        return accountIdHex
    }
}
