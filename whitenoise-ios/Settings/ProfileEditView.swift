import SwiftUI
import MarmotKit
import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// Edit the Nostr kind:0 profile for the currently active account. Marmot
/// chooses the account relay lists; iOS only supplies the edited metadata.
struct ProfileEditView: View {
    @Environment(AppState.self) private var appState
    @State private var model = ProfileEditViewModel()
    @State private var showImagePicker = false
    @State private var showMoreFields = false
    @State private var isEditing = false
    @State private var editSnapshot: ProfileEditDraftSnapshot?

    var body: some View {
        @Bindable var model = model
        return Form {
            avatarSection

            Section("Name") {
                if isEditing {
                    TextField("Name", text: $model.displayName)
                } else {
                    Text(model.displayName.isEmpty ? L10n.string("Not set") : model.displayName)
                        .foregroundStyle(model.displayName.isEmpty ? .secondary : .primary)
                }
            }

            Section {
                if isEditing {
                    TextField("Verified Nostr Address", text: $model.nip05)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } else {
                    Text(model.nip05.isEmpty ? L10n.string("Not set") : model.nip05)
                        .foregroundStyle(model.nip05.isEmpty ? .secondary : .primary)
                }
                if let invalidNip05Message = model.invalidNip05Message, isEditing {
                    Label(invalidNip05Message, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Verified Nostr Address")
            } footer: {
                if isEditing && model.invalidNip05Message != nil {
                    Text("Enter an address like name@example.com.")
                }
            }

            Section("About") {
                if isEditing {
                    TextField("A little about you", text: $model.about, axis: .vertical)
                        .lineLimit(3...6)
                } else {
                    Text(model.about.isEmpty ? L10n.string("A little about you") : model.about)
                        .foregroundStyle(model.about.isEmpty ? .secondary : .primary)
                }
            }

            if isEditing {
                Section {
                    DisclosureGroup(isExpanded: $showMoreFields) {
                        TextField("Profile Image URL", text: $model.picture)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        if let invalidPictureMessage = model.invalidPictureMessage {
                            Label(invalidPictureMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }

                        TextField("Banner Image URL", text: $model.banner)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        if let invalidBannerMessage = model.invalidBannerMessage {
                            Label(invalidBannerMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    } label: {
                        Text("More")
                    }
                }
            }

            if model.error != nil {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Couldn't load this screen", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Button("Retry") {
                            Task { await model.loadExisting(using: appState) }
                        }
                    }
                }
            }
        }
        .localizedNavigationTitle("Profile")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isEditing)
        .toolbar {
            if isEditing {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: cancelEditing)
                        .disabled(model.isPublishing || model.isUploadingPicture)
                }
            }

            ToolbarItem(placement: .primaryAction) {
                if isEditing {
                    Button(model.isPublishing ? "Publishing…" : "Done") {
                        Task {
                            await model.publish(using: appState)
                            if model.error == nil {
                                isEditing = false
                                editSnapshot = nil
                            }
                        }
                    }
                    .wnPrimaryButtonStyle()
                    .disabled(saveDisabled)
                } else {
                    Button("Edit", action: beginEditing)
                        .disabled(model.loadedAccountIdHex == nil)
                }
            }
        }
        .task(id: appState.activeAccount?.accountIdHex) { await model.loadExisting(using: appState) }
        .sheet(isPresented: $showImagePicker) {
            if let active = appState.activeAccount {
                ProfileImagePickerSheet(
                    accountIdHex: active.accountIdHex,
                    title: model.displayName.isEmpty
                        ? appState.shortNpub(forAccountIdHex: active.accountIdHex)
                        : model.displayName,
                    currentURL: ContentSanitizer.imageURL(model.picture),
                    onSave: ProfileImageSaveSubmitter { draft in
                        try await model.updatePicture(with: draft, using: appState)
                    }
                )
                .appAppearance()
            }
        }
    }

    @ViewBuilder
    private var avatarSection: some View {
        if let active = appState.activeAccount {
            Section {
                VStack(spacing: 0) {
                    AvatarBubble(
                        seed: active.accountIdHex,
                        title: model.displayName.isEmpty
                            ? appState.shortNpub(forAccountIdHex: active.accountIdHex)
                            : model.displayName,
                        pictureURL: ContentSanitizer.imageURL(model.picture)
                    )
                    .frame(width: 112, height: 112)

                    if isEditing {
                        Button(model.picture.isEmpty ? "Add Photo" : "Change Photo") {
                            showImagePicker = true
                        }
                        .wnAvatarActionButtonStyle()
                        .padding(.top)
                        .disabled(
                            model.isPublishing
                                || model.isUploadingPicture
                                || model.loadedAccountIdHex != active.accountIdHex
                        )
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }

    private func beginEditing() {
        editSnapshot = ProfileEditDraftSnapshot(model: model)
        isEditing = true
    }

    private func cancelEditing() {
        editSnapshot?.restore(model)
        model.error = nil
        editSnapshot = nil
        showMoreFields = false
        isEditing = false
    }

    /// Stays in the view because it also reads `appState.activeAccountRef`; the
    /// draft validation it consults lives on the model's `currentDraft`.
    private var saveDisabled: Bool {
        model.isPublishing
            || model.isUploadingPicture
            || appState.activeAccountRef == nil
            || model.loadedAccountIdHex != appState.activeAccount?.accountIdHex
            || ContentSanitizer.displayName(model.displayName) == nil
            || model.currentDraft.validationError != nil
    }
}

private struct ProfileEditDraftSnapshot {
    let displayName: String
    let about: String
    let picture: String
    let banner: String
    let nip05: String

    init(model: ProfileEditViewModel) {
        displayName = model.displayName
        about = model.about
        picture = model.picture
        banner = model.banner
        nip05 = model.nip05
    }

    func restore(_ model: ProfileEditViewModel) {
        model.displayName = displayName
        model.about = about
        model.picture = picture
        model.banner = banner
        model.nip05 = nip05
    }
}

/// What `loadExisting` should do when the profile lookup settles: seed the
/// form, unlock a first publish (fresh identity, definitively no kind:0), or
/// stay gated because the read itself threw and publishing could replace
/// existing metadata with blanks. The distinction rides on the throwing
/// `userProfile` read — a nil return is authoritative absence, a throw is
/// unknown state.
nonisolated enum ProfileEditLoadResolution: Equatable {
    case seedExisting
    case enableFirstPublish
    case loadFailed

    static func resolve(
        hasLoadedProfile: Bool,
        readFailed: Bool
    ) -> ProfileEditLoadResolution {
        // The throwing read is the only authority. A failure gates
        // publishing outright, and a successful nil is definitive absence —
        // the display cache gets no vote in either direction, because a
        // stale projection could otherwise unlock a republish of old fields.
        if readFailed { return .loadFailed }
        return hasLoadedProfile ? .seedExisting : .enableFirstPublish
    }
}

nonisolated enum ProfileEditLoadSeeding {
    static func isDifferentLoadedAccount(previousAccountId: String?, loading accountId: String) -> Bool {
        guard let previousAccountId else { return false }
        return previousAccountId != accountId
    }
}

nonisolated enum ProfileEditFieldSeeding {
    /// On a switch to a different account, adopt that account's value; otherwise
    /// only fill an empty field so in-progress edits survive a same-account reload.
    static func seeded(current: String, loaded: String, isNewAccount: Bool) -> String {
        if isNewAccount || current.isEmpty { return loaded }
        return current
    }
}

nonisolated struct ProfileEditFormFields: Equatable {
    var displayName: String
    var about: String
    var picture: String
    var banner: String
    var nip05: String
    var lud16: String

    init(profile: UserProfileMetadataFfi) {
        displayName = ContentSanitizer.displayName(profile.displayName)
            ?? ContentSanitizer.displayName(profile.name)
            ?? ""
        about = profile.about ?? ""
        picture = profile.picture ?? ""
        banner = profile.banner ?? ""
        nip05 = profile.nip05 ?? ""
        lud16 = profile.lud16 ?? ""
    }
}

nonisolated enum ProfileEditMetadataField: Equatable {
    case picture
    case banner
    case nip05
}

nonisolated struct ProfileEditMetadataDraft: Equatable {
    var displayName: String
    var about: String
    var picture: String
    var banner: String
    var nip05: String
    // lud16 is not editable on this screen. It is carried forward verbatim from
    // the existing profile so publishing a kind:0 replacement never blanks it.
    var preservedLud16: String?

    init(
        displayName: String,
        about: String,
        picture: String,
        banner: String = "",
        nip05: String,
        preservedLud16: String?
    ) {
        self.displayName = displayName
        self.about = about
        self.picture = picture
        self.banner = banner
        self.nip05 = nip05
        self.preservedLud16 = preservedLud16
    }

    var validationError: ProfileEditMetadataField? {
        if !trimmedPicture.isEmpty, normalizedPictureURL == nil {
            return .picture
        }
        if !trimmedBanner.isEmpty, normalizedBannerURL == nil {
            return .banner
        }
        if !trimmedNip05.isEmpty, normalizedNip05 == nil {
            return .nip05
        }
        return nil
    }

    var normalizedMetadata: ProfileEditMetadata? {
        guard validationError == nil else { return nil }
        let normalizedName = ContentSanitizer.displayName(displayName)
        return ProfileEditMetadata(
            // One visible Name field must not leave a stale alternate name.
            name: normalizedName,
            displayName: normalizedName,
            about: ContentSanitizer.multilineText(about),
            picture: normalizedPictureURL,
            banner: normalizedBannerURL,
            nip05: normalizedNip05,
            lud16: preservedLud16
        )
    }

    private var trimmedPicture: String {
        picture.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedNip05: String {
        nip05.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedBanner: String {
        banner.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var normalizedPictureURL: String? {
        guard !trimmedPicture.isEmpty else { return nil }
        return ContentSanitizer.imageURL(trimmedPicture)?.absoluteString
    }

    private var normalizedNip05: String? {
        ContentSanitizer.profileAddress(trimmedNip05)
    }

    private var normalizedBannerURL: String? {
        guard !trimmedBanner.isEmpty else { return nil }
        return ContentSanitizer.imageURL(trimmedBanner)?.absoluteString
    }
}

nonisolated struct ProfileEditMetadata: Equatable {
    var name: String?
    var displayName: String?
    var about: String?
    var picture: String?
    var banner: String?
    var nip05: String?
    var lud16: String?

    var ffi: UserProfileMetadataFfi {
        UserProfileMetadataFfi(
            name: name,
            displayName: displayName,
            about: about,
            picture: picture,
            banner: banner,
            nip05: nip05,
            lud16: lud16
        )
    }
}

enum ProfileImageProgressPhase: Equatable {
    case preparing
    case uploading

    var label: String {
        switch self {
        case .preparing:
            L10n.string("Preparing image…")
        case .uploading:
            L10n.string("Uploading profile image…")
        }
    }
}

/// Keeps the async save callback out of the SwiftUI value type. This mirrors
/// the group-image submitter and avoids the debug-build closure marshalling
/// issue that previously affected async view callbacks with image data.
@MainActor
final class ProfileImageSaveSubmitter {
    private let run: (GroupImageUploadDraft?) async throws -> Void

    init(_ run: @escaping (GroupImageUploadDraft?) async throws -> Void) {
        self.run = run
    }

    func save(_ draft: GroupImageUploadDraft?) async throws {
        try await run(draft)
    }
}

struct ProfileImagePickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let accountIdHex: String
    let title: String
    let currentURL: URL?
    let onSave: ProfileImageSaveSubmitter
    var searchClient = DuckDuckGoImageSearchClient()

    @State private var draft: GroupImageUploadDraft?
    @State private var searchQuery = ""
    @State private var searchResults: [GroupImageSearchResult] = []
    @State private var searchError: String?
    @State private var saveError: String?
    @State private var isSearching = false
    @State private var isPreparing = false
    @State private var isUploading = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var cropSource: AvatarImageCropSource?
    @State private var progressPhase: ProfileImageProgressPhase?

    private let resultColumns = [
        GridItem(.adaptive(minimum: 108), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    previewSection
                    deviceSection
                    searchSection

                    if let saveError {
                        ProfileImagePickerSection {
                            Label(saveError, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 20)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .scrollDismissesKeyboard(.interactively)
            .localizedNavigationTitle("Profile image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isUploading)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Image") {
                        Task { await save(draft) }
                    }
                    .disabled(draft == nil || isBusy)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
        .interactiveDismissDisabled(isUploading)
        .sheet(isPresented: $showPhotoPicker) {
            PhotoLibraryPickerView(
                selectionLimit: 1,
                filter: .images,
                onSelection: { selections in
                    guard let selection = selections.first else { return }
                    preparePhotoSelection(selection)
                },
                onError: { error in
                    saveError = error.localizedDescription
                },
                onDismiss: {
                    showPhotoPicker = false
                }
            )
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false,
            onCompletion: prepareFileSelection
        )
        .fullScreenCover(item: $cropSource) { source in
            AvatarImageCropEditor(source: source) { source, croppedData in
                beginPreparing()
                Task {
                    await prepare(
                        data: croppedData,
                        fileName: source.fileName,
                        typeIdentifier: "public.jpeg",
                        sourceURL: source.sourceURL
                    )
                }
            }
        }
    }

    private var previewSection: some View {
        VStack(spacing: 8) {
            AvatarBubble(
                seed: accountIdHex,
                title: title,
                pictureURL: draft == nil ? currentURL : nil,
                pictureImage: draft?.thumbnail
            )
            .frame(width: 88, height: 88)
            .overlay {
                if progressPhase != nil {
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 42, height: 42)
                        ProgressView()
                    }
                    .transition(.opacity.combined(with: .scale))
                }
            }

            ZStack {
                Text(ProfileImageProgressPhase.preparing.label)
                    .hidden()
                    .accessibilityHidden(true)
                Text(ProfileImageProgressPhase.uploading.label)
                    .hidden()
                    .accessibilityHidden(true)

                if let progressPhase {
                    Text(progressPhase.label)
                        .transition(.opacity)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityHidden(progressPhase == nil)
        }
        .animation(.easeInOut(duration: 0.2), value: progressPhase)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private var deviceSection: some View {
        ProfileImagePickerSection("Choose from your device") {
            Button {
                showPhotoPicker = true
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(isBusy)

            Divider()

            Button {
                showFileImporter = true
            } label: {
                Label("Files", systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(isBusy)

            if currentURL != nil {
                Divider()

                Button(role: .destructive) {
                    Task { await save(nil) }
                } label: {
                    Label("Remove image", systemImage: "trash")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(isBusy)
            }
        }
    }

    private var searchSection: some View {
        ProfileImagePickerSection("Search the web") {
            HStack(spacing: 8) {
                TextField("Image search", text: $searchQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .disabled(isBusy)
                    .onSubmit { startSearch() }

                Button {
                    startSearch()
                } label: {
                    if isSearching || isPreparing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(searchButtonDisabled)
                .accessibilityLabel("Search the web")
            }

            Label(
                L10n.string("Web search sends your query and IP address to DuckDuckGo and image hosts."),
                systemImage: "lock.shield"
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if let searchError {
                Label(searchError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if !searchResults.isEmpty {
                // Keep async thumbnails out of Form rows; iOS 26 can recurse during collection self-sizing.
                LazyVGrid(columns: resultColumns, spacing: 12) {
                    ForEach(searchResults) { result in
                        Button {
                            prepareSearchResult(result)
                        } label: {
                            GroupImageResultCell(
                                result: result,
                                isSelected: result.imageURL.absoluteString == draft?.sourceURL
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusy)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var isBusy: Bool {
        isSearching || isPreparing || isUploading
    }

    private var searchButtonDisabled: Bool {
        GroupImageURLSheet.preparedSearchQuery(
            searchQuery,
            isSearching: isSearching,
            isSaving: isPreparing || isUploading
        ) == nil
    }

    private func startSearch() {
        guard let query = GroupImageURLSheet.preparedSearchQuery(
            searchQuery,
            isSearching: isSearching,
            isSaving: isPreparing || isUploading
        ) else { return }
        isSearching = true
        searchError = nil
        Task { await search(query: query) }
    }

    private func search(query: String) async {
        defer { isSearching = false }
        do {
            let results = try await searchClient.search(query)
            guard GroupImageURLSheet.shouldApplySearchCompletion(
                issuedQuery: query,
                currentQuery: searchQuery,
                isCancelled: Task.isCancelled
            ) else { return }
            searchResults = results
            if results.isEmpty {
                searchError = L10n.string("No usable HTTPS images found.")
            }
        } catch {
            guard GroupImageURLSheet.shouldApplySearchCompletion(
                issuedQuery: query,
                currentQuery: searchQuery,
                isCancelled: Task.isCancelled
            ) else { return }
            searchError = error.localizedDescription
        }
    }

    private func preparePhotoSelection(_ selection: PhotoLibrarySelection) {
        saveError = nil
        cropSource = AvatarImageCropSource(
            data: selection.data,
            fileName: selection.fileName,
            typeIdentifier: selection.typeIdentifier,
            sourceURL: nil
        )
    }

    private func prepareFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .failure(let error):
            saveError = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            let isSecurityScoped = url.startAccessingSecurityScopedResource()
            Task {
                defer {
                    if isSecurityScoped {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    let data = try await Task.detached(priority: .userInitiated) {
                        try AvatarImageCropper.boundedFileData(from: url)
                    }.value
                    cropSource = AvatarImageCropSource(
                        data: data,
                        fileName: url.lastPathComponent,
                        typeIdentifier: nil,
                        sourceURL: nil
                    )
                } catch {
                    saveError = error.localizedDescription
                    Haptics.error()
                }
            }
        }
    }

    private func prepareSearchResult(_ result: GroupImageSearchResult) {
        Task {
            do {
                let data = try await RemoteImageFetch.imageData(for: result.imageURL)
                cropSource = AvatarImageCropSource(
                    data: data,
                    fileName: result.imageURL.lastPathComponent,
                    typeIdentifier: nil,
                    sourceURL: result.imageURL
                )
            } catch {
                saveError = error.localizedDescription
                Haptics.error()
            }
        }
    }

    private func prepare(
        data: Data,
        fileName: String?,
        typeIdentifier: String?,
        sourceURL: URL?
    ) async {
        do {
            draft = try await GroupImageDraftProcessor.prepare(
                data: data,
                fileName: fileName,
                typeIdentifier: typeIdentifier,
                sourceURL: sourceURL
            )
            Haptics.selection()
        } catch {
            saveError = error.localizedDescription
            Haptics.error()
        }
        finishPreparing()
    }

    private func beginPreparing() {
        isPreparing = true
        progressPhase = .preparing
        saveError = nil
    }

    private func finishPreparing() {
        isPreparing = false
        progressPhase = nil
    }

    private func save(_ draft: GroupImageUploadDraft?) async {
        isUploading = true
        progressPhase = draft == nil ? nil : .uploading
        saveError = nil
        defer {
            isUploading = false
            progressPhase = nil
        }
        do {
            try await onSave.save(draft)
            dismiss()
        } catch {
            saveError = error.localizedDescription
            Haptics.error()
        }
    }
}

private struct ProfileImagePickerSection<Content: View>: View {
    private let title: LocalizedStringKey?
    private let content: Content

    init(
        _ title: LocalizedStringKey? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 4)
            }

            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                Color(uiColor: .secondarySystemGroupedBackground),
                in: .rect(cornerRadius: 12)
            )
        }
    }
}
