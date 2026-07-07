import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct ProfileEditMetadataDraftTests {
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
        #expect(!ProfileEditLoadSeeding.isDifferentLoadedAccount(previousAccountId: "account-a", loading: "account-a"))
        #expect(ProfileEditLoadSeeding.isDifferentLoadedAccount(previousAccountId: "account-a", loading: "account-b"))
    }

    @Test func adoptsDifferentAccountValueEvenWhenFieldIsNonEmpty() {
        #expect(ProfileEditFieldSeeding.seeded(current: "Alice", loaded: "Bob", isNewAccount: true) == "Bob")
        #expect(ProfileEditFieldSeeding.seeded(current: "Alice", loaded: "", isNewAccount: true) == "")
    }
}
