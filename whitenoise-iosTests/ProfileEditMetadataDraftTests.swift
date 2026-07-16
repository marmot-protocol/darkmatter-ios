import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct ProfileEditMetadataDraftTests {
    @MainActor
    @Test func accountTransitionResetsEditableFieldsBeforeFirstPublish() {
        let model = ProfileEditViewModel()
        // Account A: fresh identity, user typed a draft; load settles.
        model.displayName = "Alice draft"
        model.about = "About A"
        model.applyLoadOutcome(.enableFirstPublish, accountIdHex: "account-a", profile: nil)
        #expect(model.displayName == "Alice draft")
        #expect(model.loadedAccountIdHex == "account-a")

        // Switch to fresh account B: A's typed fields must not survive to
        // become publishable under B.
        model.applyLoadOutcome(.enableFirstPublish, accountIdHex: "account-b", profile: nil)
        #expect(model.displayName.isEmpty)
        #expect(model.about.isEmpty)
        #expect(model.loadedAccountIdHex == "account-b")
    }

    @MainActor
    @Test func failedReadAfterAccountTransitionClearsFieldsAndKeepsSaveGated() {
        let model = ProfileEditViewModel()
        model.displayName = "Alice draft"
        model.applyLoadOutcome(.enableFirstPublish, accountIdHex: "account-a", profile: nil)

        model.applyLoadOutcome(.loadFailed, accountIdHex: "account-b", profile: nil)
        #expect(model.displayName.isEmpty)
        #expect(model.error != nil)
        // The gate stays on A: saveDisabled compares against the active
        // account, so B cannot publish until a load succeeds for B.
        #expect(model.loadedAccountIdHex == "account-a")
    }

    @Test func formFieldsPreserveNameWithoutSeedingDisplayNameFromIt() {
        let profile = UserProfileMetadataFfi(
            name: "alice",
            displayName: nil,
            about: nil,
            picture: nil,
            nip05: nil,
            lud16: nil
        )

        let formFields = ProfileEditFormFields(profile: profile)
        #expect(formFields.name == "alice")
        #expect(formFields.displayName == "")
    }

    @Test func preservesExistingNameWhenDisplayNameChanges() throws {
        let draft = ProfileEditMetadataDraft(
            name: "alice",
            displayName: "Alice 🎉",
            about: "",
            picture: "",
            nip05: "alice@example.com",
            preservedLud16: nil
        )

        let metadata = try #require(draft.normalizedMetadata)
        #expect(metadata.name == "alice")
        #expect(metadata.displayName == "Alice 🎉")
        #expect(metadata.nip05 == "alice@example.com")
    }

    @Test func doesNotInventNameFromDisplayName() throws {
        let draft = ProfileEditMetadataDraft(
            name: nil,
            displayName: "Alice 🎉",
            about: "",
            picture: "",
            nip05: "",
            preservedLud16: nil
        )

        let metadata = try #require(draft.normalizedMetadata)
        #expect(metadata.name == nil)
        #expect(metadata.displayName == "Alice 🎉")
    }

    @Test func normalizesValidHttpsPictureURL() throws {
        let draft = ProfileEditMetadataDraft(
            name: nil,
            displayName: "Alice",
            about: "",
            picture: " https://cdn.example.com/avatar.png ",
            nip05: "",
            preservedLud16: nil
        )

        let metadata = try #require(draft.normalizedMetadata)
        #expect(metadata.picture == "https://cdn.example.com/avatar.png")
    }

    @Test func rejectsInvalidPictureURLBeforePublish() {
        let draft = ProfileEditMetadataDraft(
            name: nil,
            displayName: "Alice",
            about: "",
            picture: "http://legacy.example/a.png",
            nip05: "",
            preservedLud16: nil
        )

        #expect(draft.validationError == .picture)
        #expect(draft.normalizedMetadata == nil)
    }

    @Test func blankPictureClearsPublishedMetadata() throws {
        let draft = ProfileEditMetadataDraft(
            name: nil,
            displayName: "Alice",
            about: "",
            picture: "   ",
            nip05: "",
            preservedLud16: nil
        )

        let metadata = try #require(draft.normalizedMetadata)
        #expect(metadata.picture == nil)
    }

    @Test func seedsEmptyFieldOnSameAccountReloadWithoutClobberingEdits() {
        #expect(ProfileEditFieldSeeding.seeded(current: "", loaded: "Alice", isNewAccount: false) == "Alice")
        #expect(ProfileEditFieldSeeding.seeded(current: "Al", loaded: "Alice", isNewAccount: false) == "Al")
    }

    @Test func firstLoadDoesNotCountAsDifferentLoadedAccount() {
        #expect(!ProfileEditLoadSeeding.isDifferentLoadedAccount(previousAccountId: nil, loading: "account-a"))
        // A fresh identity (projection exists, no kind:0 anywhere) unlocks a
        // first publish; a failed load stays gated — publishing then could
        // replace existing metadata with blanks.
        #expect(ProfileEditLoadResolution.resolve(
            hasLoadedProfile: false, hasCachedProfile: false, readFailed: false
        ) == .enableFirstPublish)
        #expect(ProfileEditLoadResolution.resolve(
            hasLoadedProfile: false, hasCachedProfile: false, readFailed: true
        ) == .loadFailed)
        #expect(ProfileEditLoadResolution.resolve(
            hasLoadedProfile: true, hasCachedProfile: false, readFailed: false
        ) == .seedExisting)
        // A failed read still seeds from cache — matching the pre-existing
        // cache-fallback behavior.
        #expect(ProfileEditLoadResolution.resolve(
            hasLoadedProfile: false, hasCachedProfile: true, readFailed: true
        ) == .seedExisting)
        #expect(!ProfileEditLoadSeeding.isDifferentLoadedAccount(previousAccountId: "account-a", loading: "account-a"))
        #expect(ProfileEditLoadSeeding.isDifferentLoadedAccount(previousAccountId: "account-a", loading: "account-b"))
    }

    @Test func adoptsDifferentAccountValueEvenWhenFieldIsNonEmpty() {
        #expect(ProfileEditFieldSeeding.seeded(current: "Alice", loaded: "Bob", isNewAccount: true) == "Bob")
        #expect(ProfileEditFieldSeeding.seeded(current: "Alice", loaded: "", isNewAccount: true) == "")
    }
}
