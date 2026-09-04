import Foundation
import Testing
@testable import MarmotKit
@testable import whitenoise_ios

private let candidate = DataSharingOptInCandidate(
    accountRef: "npub-entered",
    accountIdHex: "AB12"
)

/// Neither switch turned on: the state the offer exists for.
private let unanswered = DataSharingChoices(telemetryEnabled: false, auditLoggingEnabled: false)

struct DataSharingOptInPolicyTests {
    @Test func offersOnFirstEntryOfAReadyIdentity() {
        #expect(DataSharingOptInPolicy.accountIdHexToOffer(
            candidate,
            phase: .ready,
            activeAccountRef: candidate.accountRef,
            alreadyOffered: [],
            choices: unanswered
        ) == "ab12")
    }

    @Test func refusesEveryPhaseButReady() {
        for phase in [AppState.Phase.bootstrapping, .onboarding, .failed("nope")] {
            #expect(DataSharingOptInPolicy.accountIdHexToOffer(
                candidate,
                phase: phase,
                activeAccountRef: candidate.accountRef,
                alreadyOffered: [],
                choices: unanswered
            ) == nil)
        }
    }

    /// An identity with no hex cannot be recorded as asked, so asking it would
    /// repeat on every entry.
    @Test func refusesAnIdentityThatCannotBeRecorded() {
        let blank = DataSharingOptInCandidate(accountRef: "npub-entered", accountIdHex: "   ")

        #expect(DataSharingOptInPolicy.accountIdHexToOffer(
            blank,
            phase: .ready,
            activeAccountRef: blank.accountRef,
            alreadyOffered: [],
            choices: unanswered
        ) == nil)
    }

    /// A switch from Settings landing during activation leaves a different
    /// identity active; the offer is dropped rather than spent on it.
    @Test func refusesWhenAnotherIdentityBecameActive() {
        #expect(DataSharingOptInPolicy.accountIdHexToOffer(
            candidate,
            phase: .ready,
            activeAccountRef: "npub-someone-else",
            alreadyOffered: [],
            choices: unanswered
        ) == nil)

        #expect(DataSharingOptInPolicy.accountIdHexToOffer(
            candidate,
            phase: .ready,
            activeAccountRef: nil,
            alreadyOffered: [],
            choices: unanswered
        ) == nil)
    }

    /// The switches are runtime-global, so a second identity arrives with the
    /// first one's answer already in place. Offering an opt-in over an enabled
    /// switch would present a settled decision as a fresh choice, and closing the
    /// sheet — which reads as declining — would leave it enabled.
    @Test func refusesWhenEitherSwitchIsAlreadyOn() {
        let answered = [
            DataSharingChoices(telemetryEnabled: true, auditLoggingEnabled: false),
            DataSharingChoices(telemetryEnabled: false, auditLoggingEnabled: true),
            DataSharingChoices(telemetryEnabled: true, auditLoggingEnabled: true)
        ]

        for choices in answered {
            #expect(DataSharingOptInPolicy.accountIdHexToOffer(
                candidate,
                phase: .ready,
                activeAccountRef: candidate.accountRef,
                alreadyOffered: [],
                choices: choices
            ) == nil)
        }
    }

    @Test func onlyBothSwitchesOffCountsAsUnanswered() {
        #expect(unanswered.isUnanswered)
        #expect(!DataSharingChoices(telemetryEnabled: true, auditLoggingEnabled: false).isUnanswered)
        #expect(!DataSharingChoices(telemetryEnabled: false, auditLoggingEnabled: true).isUnanswered)
    }

    @Test func refusesAnIdentityAlreadyOffered() {
        #expect(DataSharingOptInPolicy.accountIdHexToOffer(
            candidate,
            phase: .ready,
            activeAccountRef: candidate.accountRef,
            alreadyOffered: ["ab12"],
            choices: unanswered
        ) == nil)
    }
}

struct DataSharingOptInStoreTests {
    @Test func recordsAndForgetsOneIdentity() {
        let defaults = IsolatedAccountDefaults.make()

        #expect(DataSharingOptInStore.offeredAccountIdHexes(defaults: defaults).isEmpty)

        DataSharingOptInStore.markOffered(accountIdHex: "AB12", defaults: defaults)
        #expect(DataSharingOptInStore.offeredAccountIdHexes(defaults: defaults) == ["ab12"])

        DataSharingOptInStore.forget(accountIdHex: " ab12 ", defaults: defaults)
        #expect(DataSharingOptInStore.offeredAccountIdHexes(defaults: defaults).isEmpty)
    }

    /// Case and stray whitespace must address the same record, or a re-read
    /// spelled differently re-offers a choice the identity already made.
    @Test func normalizesTheStorageForm() {
        let defaults = IsolatedAccountDefaults.make()

        DataSharingOptInStore.markOffered(accountIdHex: " AB12 ", defaults: defaults)
        DataSharingOptInStore.markOffered(accountIdHex: "ab12", defaults: defaults)

        #expect(DataSharingOptInStore.offeredAccountIdHexes(defaults: defaults) == ["ab12"])
    }

    @Test func ignoresBlankIdentifiers() {
        let defaults = IsolatedAccountDefaults.make()

        DataSharingOptInStore.markOffered(accountIdHex: "   ", defaults: defaults)

        #expect(DataSharingOptInStore.offeredAccountIdHexes(defaults: defaults).isEmpty)
        #expect(defaults.stringArray(forKey: DataSharingOptInStore.storageKey) == nil)
    }

    /// Forgetting the last record must remove the key, not leave an empty array
    /// behind for the next read to parse.
    @Test func forgettingTheLastRecordClearsStorage() {
        let defaults = IsolatedAccountDefaults.make()

        DataSharingOptInStore.markOffered(accountIdHex: "ab12", defaults: defaults)
        DataSharingOptInStore.forget(accountIdHex: "ab12", defaults: defaults)

        #expect(defaults.stringArray(forKey: DataSharingOptInStore.storageKey) == nil)
    }
}

@MainActor
struct DataSharingOptInPresentationTests {
    @Test func offersOncePerIdentityThenNeverAgain() async throws {
        let appState = makeReadyAppState()
        let summary = summaryFfi(label: "npub-a", accountIdHex: "AB12")
        appState.activeAccountRef = summary.label

        await offerDataSharingOptIn(on: appState, for: summary)
        #expect(appState.isDataSharingOptInPresented)

        appState.dismissDataSharingOptIn()
        await offerDataSharingOptIn(on: appState, for: summary)
        #expect(!appState.isDataSharingOptInPresented)
    }

    /// A destructive wipe drops the record, so a later sign-in with the same key
    /// is asked again rather than inheriting an answer it can no longer see.
    @Test func aWipedIdentityIsAskedAgain() async throws {
        let appState = makeReadyAppState()
        let summary = summaryFfi(label: "npub-a", accountIdHex: "AB12")
        appState.activeAccountRef = summary.label

        await offerDataSharingOptIn(on: appState, for: summary)
        appState.dismissDataSharingOptIn()
        appState.forgetDataSharingOptIn(accountIdHex: summary.accountIdHex)

        await offerDataSharingOptIn(on: appState, for: summary)
        #expect(appState.isDataSharingOptInPresented)
    }

    /// The record is written when the sheet goes up, so a quit with it still open
    /// cannot leave an identity that will never be asked — or one asked forever.
    @Test func theOfferIsRecordedEvenIfTheSheetIsNeverDismissed() async throws {
        let appState = makeReadyAppState()
        let summary = summaryFfi(label: "npub-a", accountIdHex: "AB12")
        appState.activeAccountRef = summary.label

        await offerDataSharingOptIn(on: appState, for: summary)

        #expect(DataSharingOptInStore.offeredAccountIdHexes(defaults: appState.accountDefaults) == ["ab12"])
    }

    @Test func doesNotOfferWhileStillOnboarding() async throws {
        let appState = AppState(
            client: try MarmotClient.testClient(),
            notifications: .shared,
            accountDefaults: IsolatedAccountDefaults.make()
        )
        let summary = summaryFfi(label: "npub-a", accountIdHex: "AB12")
        appState.activeAccountRef = summary.label

        await offerDataSharingOptIn(on: appState, for: summary)

        #expect(!appState.isDataSharingOptInPresented)
        #expect(DataSharingOptInStore.offeredAccountIdHexes(defaults: appState.accountDefaults).isEmpty)
    }

    /// The two steps the app takes together: the identity path arms, `RootView`
    /// resolves.
    private func offerDataSharingOptIn(on appState: AppState, for summary: AccountSummaryFfi) async {
        appState.armDataSharingOptInIfNeeded(for: summary)
        await appState.resolveDataSharingOptIn()
    }

    /// Arming is the cheap half and must not decide anything on its own: an
    /// identity is only offered the choice once the global switches have been
    /// read and found unanswered.
    @Test func armingAloneNeverPresentsTheSheet() throws {
        let appState = makeReadyAppState()
        let summary = summaryFfi(label: "npub-a", accountIdHex: "AB12")
        appState.activeAccountRef = summary.label

        appState.armDataSharingOptInIfNeeded(for: summary)

        #expect(appState.pendingDataSharingOptInCandidate != nil)
        #expect(!appState.isDataSharingOptInPresented)
        #expect(DataSharingOptInStore.offeredAccountIdHexes(defaults: appState.accountDefaults).isEmpty)
    }

    /// Resolving clears the candidate whatever the outcome, so a later arbitrary
    /// moment cannot present a sheet for an entry that has long passed.
    @Test func resolvingClearsTheArmedCandidate() async throws {
        let appState = makeReadyAppState()
        let summary = summaryFfi(label: "npub-a", accountIdHex: "AB12")
        appState.activeAccountRef = summary.label

        await offerDataSharingOptIn(on: appState, for: summary)

        #expect(appState.pendingDataSharingOptInCandidate == nil)
    }

    private func makeReadyAppState() -> AppState {
        let appState = AppState(
            client: try? MarmotClient.testClient(),
            notifications: .shared,
            accountDefaults: IsolatedAccountDefaults.make()
        )
        appState.setPhase(.ready)
        return appState
    }

    private func summaryFfi(label: String, accountIdHex: String) -> AccountSummaryFfi {
        AccountSummaryFfi(
            label: label,
            accountIdHex: accountIdHex,
            localSigning: true,
            signedOut: false,
            running: true
        )
    }
}

@MainActor
struct PrivacySecurityProjectionResilienceTests {
    /// Both switches render from this projection and disable while it is `nil`,
    /// so a fresh install — no audit files, no account — must still resolve both.
    @Test func bothSwitchesLoadOnAnInstallWithNoAuditFiles() async throws {
        let client = try MarmotClient.testClient()

        let projection = try await client.privacySecuritySettingsProjection()

        #expect(projection.telemetrySettings != nil)
        #expect(projection.auditSettings != nil)
    }
}
