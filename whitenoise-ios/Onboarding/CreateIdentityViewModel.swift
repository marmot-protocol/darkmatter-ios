import Foundation
import MarmotKit
import UIKit

@MainActor
protocol CreateIdentityServicing: AnyObject {
    func createIdentityForProfileSetup() async throws -> AccountSummaryFfi
    func onboardingProfile(accountIdHex: String) async throws -> UserProfileMetadataFfi?
    func uploadOnboardingAvatar(
        accountRef: String,
        draft: GroupImageUploadDraft
    ) async throws -> String
    func publishOnboardingProfile(
        accountRef: String,
        profile: UserProfileMetadataFfi
    ) async throws
    func completeIdentityProfileSetup(_ summary: AccountSummaryFfi) async
}

extension AppState: CreateIdentityServicing {
    func onboardingProfile(accountIdHex: String) async throws -> UserProfileMetadataFfi? {
        try await currentMarmotClient().userProfileForEditing(accountIdHex: accountIdHex)
    }

    func uploadOnboardingAvatar(
        accountRef: String,
        draft: GroupImageUploadDraft
    ) async throws -> String {
        let url = try await currentMarmotClient().uploadProfileImage(
            accountRef: accountRef,
            data: draft.data,
            mediaType: draft.mediaType,
            blossomServer: nil
        )
        guard let normalized = ContentSanitizer.imageURL(url)?.absoluteString else {
            throw ProfileImageUploadError.invalidReturnedURL
        }
        return normalized
    }

    func publishOnboardingProfile(
        accountRef: String,
        profile: UserProfileMetadataFfi
    ) async throws {
        let relayConfiguration = await relayPublishConfiguration(for: accountRef)
        _ = try await currentMarmotClient().publishUserProfile(
            accountRef: accountRef,
            profile: profile,
            defaultRelays: relayConfiguration.publishRelays,
            bootstrapRelays: relayConfiguration.bootstrapRelays
        )
    }
}

nonisolated struct OnboardingProfileMetadataDraft: Equatable {
    var displayName: String
    var about: String
    var uploadedPictureURL: String?

    var hasEdits: Bool {
        normalizedDisplayName != nil
            || normalizedAbout != nil
            || uploadedPictureURL != nil
    }

    func merging(with existing: UserProfileMetadataFfi?) -> UserProfileMetadataFfi? {
        guard hasEdits else { return nil }
        return UserProfileMetadataFfi(
            name: existing?.name,
            displayName: normalizedDisplayName ?? existing?.displayName,
            about: normalizedAbout ?? existing?.about,
            picture: uploadedPictureURL ?? existing?.picture,
            banner: existing?.banner,
            nip05: existing?.nip05,
            lud16: existing?.lud16
        )
    }

    private var normalizedDisplayName: String? {
        ContentSanitizer.displayName(displayName)
    }

    private var normalizedAbout: String? {
        ContentSanitizer.multilineText(about)
    }
}

/// Screen store for `CreateIdentityView`: owns the in-flight/error state and the
/// create/profile action, including the identity returned before optional
/// metadata is published. Keeping that identity in the model makes profile
/// retries idempotent: they never call create a second time.
@MainActor
@Observable
final class CreateIdentityViewModel {
    enum Phase: Equatable {
        case editing
        case creating
        case creationFailed
        case savingProfile
        case profileSaveFailed
    }

    var displayName = ""
    var about = ""
    private(set) var avatarDraft: GroupImageUploadDraft?
    private(set) var avatarError: String?
    private(set) var isPreparingAvatar = false
    private(set) var phase: Phase = .editing

    private(set) var createdIdentity: AccountSummaryFfi?
    private var existingProfile: UserProfileMetadataFfi?
    private var loadedExistingProfile = false
    private var prefilledDisplayName: String?
    private var uploadedAvatarURL: String?

    var isSubmitting: Bool {
        phase == .creating || phase == .savingProfile
    }

    var isSavingProfile: Bool {
        phase == .savingProfile
    }

    var isBusy: Bool {
        isPreparingAvatar || isSubmitting
    }

    var allowsBackNavigation: Bool {
        !isSubmitting && createdIdentity == nil
    }

    var failureMessage: String? {
        switch phase {
        case .creationFailed:
            L10n.string("Couldn't create your profile. Try again.")
        case .profileSaveFailed:
            L10n.string("Your profile was created, but some details couldn't be saved.")
        case .editing, .creating, .savingProfile:
            nil
        }
    }

    func setAvatarDraft(_ draft: GroupImageUploadDraft?) {
        guard !isSavingProfile else { return }
        avatarDraft = draft
        uploadedAvatarURL = nil
        avatarError = nil
    }

    func prepareAvatar(from selection: PhotoLibrarySelection) async {
        await prepareAvatar(
            data: selection.data,
            fileName: selection.fileName,
            typeIdentifier: selection.typeIdentifier
        )
    }

    func prepareAvatar(
        data: Data,
        fileName: String?,
        typeIdentifier: String?
    ) async {
        guard !isPreparingAvatar, !isSavingProfile else { return }
        avatarError = nil
        isPreparingAvatar = true
        defer { isPreparingAvatar = false }
        do {
            setAvatarDraft(try await ProfileImageDraftProcessor.prepare(
                data: data,
                fileName: fileName,
                typeIdentifier: typeIdentifier
            ))
            Haptics.selection()
        } catch {
            setAvatarPreparationError(error)
        }
    }

    func setAvatarPreparationError(_ error: Error) {
        if case MediaDraftProcessor.Failure.attachmentTooLarge = error {
            avatarError = L10n.string("That photo is too large. Choose a different photo.")
        } else {
            avatarError = L10n.string("That photo can't be used. Choose a different photo.")
        }
        Haptics.error()
    }

    /// Creates the identity and loads Marmot's generated profile before the
    /// user starts editing. Marmot owns the pseudonym, so Swift reads it back
    /// instead of maintaining a second copy of the name-generation rules.
    func prepare(using service: CreateIdentityServicing) async {
        guard !isBusy, !loadedExistingProfile else { return }

        let performance = HostActionPerformance.begin()
        phase = .creating
        do {
            if createdIdentity == nil {
                createdIdentity = try await service.createIdentityForProfileSetup()
            }
            guard let createdIdentity else { return }
            try await loadExistingProfile(for: createdIdentity, using: service)
            phase = .editing
            HostActionPerformance.record("identity_prepare", since: performance)
        } catch {
            phase = .creationFailed
            HostActionPerformance.record("identity_prepare_failed", since: performance)
            Haptics.error()
        }
    }

    func submit(
        using service: CreateIdentityServicing,
        dismiss: () -> Void
    ) async {
        guard !isBusy else { return }

        if createdIdentity == nil || !loadedExistingProfile {
            await prepare(using: service)
        }

        guard loadedExistingProfile, let createdIdentity else { return }
        let performance = HostActionPerformance.begin()
        phase = .savingProfile
        do {
            try await savePendingProfile(for: createdIdentity, using: service)
            await service.completeIdentityProfileSetup(createdIdentity)
            HostActionPerformance.record("identity_submit_to_ready", since: performance)
            Haptics.success()
            dismiss()
        } catch {
            HostActionPerformance.record("identity_submit_failed", since: performance)
            phase = .profileSaveFailed
            Haptics.error()
        }
    }

    func continueWithoutSaving(
        using service: CreateIdentityServicing,
        dismiss: () -> Void
    ) async {
        guard phase == .profileSaveFailed,
              let createdIdentity
        else { return }
        phase = .savingProfile
        await service.completeIdentityProfileSetup(createdIdentity)
        Haptics.success()
        dismiss()
    }

    private func savePendingProfile(
        for identity: AccountSummaryFfi,
        using service: CreateIdentityServicing
    ) async throws {
        let draftDisplayName = editedDisplayName
        let needsProfileRead = OnboardingProfileMetadataDraft(
            displayName: draftDisplayName,
            about: about,
            uploadedPictureURL: uploadedAvatarURL
        ).hasEdits || avatarDraft != nil
        guard needsProfileRead else { return }

        if !loadedExistingProfile {
            existingProfile = try await service.onboardingProfile(
                accountIdHex: identity.accountIdHex
            )
            loadedExistingProfile = true
        }

        if let avatarDraft, uploadedAvatarURL == nil {
            uploadedAvatarURL = try await service.uploadOnboardingAvatar(
                accountRef: identity.label,
                draft: avatarDraft
            )
        }

        let draft = OnboardingProfileMetadataDraft(
            displayName: draftDisplayName,
            about: about,
            uploadedPictureURL: uploadedAvatarURL
        )
        guard let profile = draft.merging(with: existingProfile) else { return }
        try await service.publishOnboardingProfile(
            accountRef: identity.label,
            profile: profile
        )
    }

    private var editedDisplayName: String {
        let normalized = ContentSanitizer.displayName(displayName)
        return normalized == prefilledDisplayName ? "" : displayName
    }

    private func loadExistingProfile(
        for identity: AccountSummaryFfi,
        using service: CreateIdentityServicing
    ) async throws {
        guard !loadedExistingProfile else { return }

        let profile = try await service.onboardingProfile(
            accountIdHex: identity.accountIdHex
        )
        existingProfile = profile
        loadedExistingProfile = true

        guard ContentSanitizer.displayName(displayName) == nil else { return }
        let generatedName = ContentSanitizer.displayName(profile?.displayName ?? "")
            ?? ContentSanitizer.displayName(profile?.name ?? "")
        guard let generatedName else { return }
        displayName = generatedName
        prefilledDisplayName = generatedName
    }
}

enum ProfileImageDraftProcessor {
    static func prepare(
        data: Data,
        fileName: String?,
        typeIdentifier: String?
    ) async throws -> GroupImageUploadDraft {
        guard !data.isEmpty, data.count <= MediaDraftProcessor.maxAttachmentBytes else {
            throw MediaDraftProcessor.Failure.attachmentTooLarge(data.count)
        }
        let attachment = try await Task.detached(priority: .userInitiated) {
            guard let image = UIImage(data: data) else {
                throw MediaDraftProcessor.Failure.unsupportedImage
            }
            return try MediaDraftProcessor.attachment(
                from: image,
                fileName: fileName,
                quality: .standard
            )
        }.value
        return GroupImageUploadDraft(
            data: attachment.data,
            mediaType: attachment.mediaType,
            sourceURL: nil,
            dim: attachment.dim,
            thumbhash: attachment.thumbhash,
            thumbnail: attachment.thumbnail
        )
    }
}
