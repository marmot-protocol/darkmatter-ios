import Foundation
import MarmotKit

/// Screen store for `ProfileEditView`: owns the editable kind:0 fields + the
/// load/publish flow, so the view is pure rendering. The validation *logic*
/// stays in the pure `ProfileEditMetadataDraft` (defined alongside the view and
/// tested directly); this exposes the live draft plus the per-field presentation
/// messages. The view keeps `saveDisabled` because it also reads
/// `appState.activeAccountRef`. `AppState` is passed into the load/publish
/// methods rather than retained.
@MainActor
@Observable
final class ProfileEditViewModel {
    var existingName: String?
    var displayName = ""
    var about = ""
    var picture = ""
    var nip05 = ""
    // Not user-editable here; preserved so a kind:0 republish keeps it.
    var existingLud16: String?

    var isPublishing = false
    var error: String?

    private(set) var loadedAccountIdHex: String?
    // The reset detector must see every attempt: a failed load never moves
    // the Save gate above, so gating alone would treat a return to the
    // previously loaded account as "same account" and let another account's
    // typed draft survive into a publishable state.
    private var lastAttemptedAccountIdHex: String?

    var currentDraft: ProfileEditMetadataDraft {
        ProfileEditMetadataDraft(
            name: existingName,
            displayName: displayName,
            about: about,
            picture: picture,
            nip05: nip05,
            preservedLud16: existingLud16
        )
    }

    var invalidPictureMessage: String? { validationMessage(for: .picture) }
    var invalidNip05Message: String? { validationMessage(for: .nip05) }

    func validationMessage(for field: ProfileEditMetadataField) -> String? {
        guard currentDraft.validationError == field else { return nil }
        switch field {
        case .picture:
            return L10n.string("Only public HTTPS image URLs are allowed.")
        case .nip05:
            return L10n.string("Enter a valid NIP-05 address like name@example.com.")
        }
    }

    func loadExisting(using appState: AppState) async {
        guard let id = appState.activeAccount?.accountIdHex else { return }
        // Publishing authorization is revoked for the whole load window and
        // re-granted only by a successful outcome — a failed or in-flight
        // load must never leave Save armed with a previous account's grant.
        loadedAccountIdHex = nil
        // The projection batch erases read errors (`try?`), so the editor
        // takes its authority from the throwing read: nil is definitive
        // absence, a throw is unknown state that must gate publishing. The
        // display cache gets no vote — it can trail the relays.
        var loadedProfile: UserProfileMetadataFfi?
        var readFailed = false
        do {
            loadedProfile = try await appState.currentMarmotClient()
                .userProfileForEditing(accountIdHex: id)
        } catch {
            readFailed = true
        }
        // The read is async; if the active account changed under us, drop the
        // result rather than seed this editor with another account's metadata.
        guard appState.activeAccount?.accountIdHex == id else { return }
        applyLoadOutcome(
            ProfileEditLoadResolution.resolve(
                hasLoadedProfile: loadedProfile != nil,
                readFailed: readFailed
            ),
            accountIdHex: id,
            profile: loadedProfile
        )
    }

    /// Split from `loadExisting` so the field state machine is testable
    /// without an `AppState`. A change of loaded account resets every
    /// editable field first — stale text typed for one account must never
    /// become publishable under another.
    func applyLoadOutcome(
        _ resolution: ProfileEditLoadResolution,
        accountIdHex id: String,
        profile: UserProfileMetadataFfi?
    ) {
        let isDifferentAccount = ProfileEditLoadSeeding.isDifferentLoadedAccount(
            previousAccountId: lastAttemptedAccountIdHex,
            loading: id
        )
        lastAttemptedAccountIdHex = id
        if isDifferentAccount {
            existingName = nil
            existingLud16 = nil
            displayName = ""
            about = ""
            picture = ""
            nip05 = ""
            error = nil
        }
        switch resolution {
        case .loadFailed:
            loadedAccountIdHex = nil
            error = L10n.string("Couldn't load your profile. Close and reopen this screen to retry.")
        case .enableFirstPublish:
            existingName = nil
            existingLud16 = nil
            loadedAccountIdHex = id
        case .seedExisting:
            guard let profile else { return }
            error = nil
            let formFields = ProfileEditFormFields(profile: profile)
            existingName = formFields.name
            existingLud16 = formFields.lud16.isEmpty ? nil : formFields.lud16
            displayName = ProfileEditFieldSeeding.seeded(
                current: displayName, loaded: formFields.displayName, isNewAccount: isDifferentAccount
            )
            about = ProfileEditFieldSeeding.seeded(
                current: about, loaded: formFields.about, isNewAccount: isDifferentAccount
            )
            picture = ProfileEditFieldSeeding.seeded(
                current: picture, loaded: formFields.picture, isNewAccount: isDifferentAccount
            )
            nip05 = ProfileEditFieldSeeding.seeded(
                current: nip05, loaded: formFields.nip05, isNewAccount: isDifferentAccount
            )
            loadedAccountIdHex = id
        }
    }

    func publish(using appState: AppState) async {
        guard !isPublishing else { return }
        guard let accountRef = appState.activeAccountRef,
              let accountIdHex = appState.activeAccount?.accountIdHex,
              // Never republish fields loaded for a now-inactive account.
              loadedAccountIdHex == accountIdHex
        else { return }

        let draft = currentDraft
        if let validationError = draft.validationError {
            Haptics.error()
            error = validationMessage(for: validationError)
            return
        }
        guard let normalizedMetadata = draft.normalizedMetadata else { return }

        isPublishing = true
        defer { isPublishing = false }
        error = nil

        do {
            let client = try appState.currentMarmotClient()
            let relays = await appState.relayPublishRelays(for: accountRef)
            let bootstrapRelays = await appState.relayBootstrapRelays(for: accountRef)
            _ = try await client.publishUserProfile(
                accountRef: accountRef,
                profile: normalizedMetadata.ffi,
                defaultRelays: relays,
                bootstrapRelays: bootstrapRelays
            )
            await appState.reloadProfileProjection(forAccountIdHex: accountIdHex)
            Haptics.success()
            appState.present(.success(
                L10n.string("Profile published"),
                message: L10n.plural("Your kind:0 metadata is live on %lld relays.", Int64(relays.count))
            ))
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
            appState.present(.error(L10n.string("Couldn't publish profile"), message: error.localizedDescription))
        }
    }
}
