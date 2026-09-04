import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Creates the real Marmot identity while presenting the designer-approved
/// Sign Up hierarchy from the onboarding prototype.
struct CreateIdentityView: View {
    private enum PendingPhotoSource {
        case photos
        case files
    }

    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var model = CreateIdentityViewModel()
    @State private var pendingPhotoSource: PendingPhotoSource?
    @State private var showAvatarDisclosure = false
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var showWebImagePicker = false
    @State private var cropSource: AvatarImageCropSource?
    @State private var isKeyboardVisible = false
    @FocusState private var nameFocused: Bool
    @FocusState private var aboutFocused: Bool

    let showsCloseButton: Bool

    init(showsCloseButton: Bool = false) {
        self.showsCloseButton = showsCloseButton
    }

    var body: some View {
        @Bindable var model = model

        Form {
            avatarSection
                .frame(maxWidth: .infinity)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

            Section("Name") {
                WNInput(
                    placeholder: L10n.string("Name"),
                    text: $model.displayName,
                    submitLabel: .next,
                    autocapitalization: .words,
                    disablesAutocorrection: false,
                    focus: $nameFocused,
                    onSubmit: { aboutFocused = true }
                )
                .textContentType(.name)
                .wnInputRow()
            }

            Section("About") {
                WNInput(
                    placeholder: L10n.string("A little about you"),
                    text: $model.about,
                    kind: .multiline(3 ... 6),
                    autocapitalization: .sentences,
                    disablesAutocorrection: false,
                    focus: $aboutFocused
                )
                .accessibilityLabel("About")
                .wnInputRow()
            }

            if let failureMessage = model.failureMessage {
                Section {
                    Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
        .disabled(model.isSavingProfile)
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .dismissesKeyboardOnTap()
        .navigationTitle("Sign Up")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(!model.allowsBackNavigation)
        .toolbar {
            if showsCloseButton && model.allowsBackNavigation {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
            }
        }
        .interactiveDismissDisabled(!model.allowsBackNavigation)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isKeyboardVisible {
                VStack(spacing: 8) {
                    WNButton(
                        title: LocalizedStringKey(primaryActionTitle),
                        isLoading: model.isSubmitting
                    ) {
                        nameFocused = false
                        aboutFocused = false
                        Task {
                            if model.phase == .creationFailed {
                                await model.prepare(using: appState)
                            } else {
                                await model.submit(using: appState, dismiss: { dismiss() })
                            }
                        }
                    }
                    .disabled(model.isBusy || !hasValidName)
                    .accessibilityLabel(primaryActionTitle)
                    .accessibilityIdentifier("sign-up.create")
                    .accessibilityValue(model.isSubmitting ? "In progress" : "")

                    if model.phase == .profileSaveFailed {
                        Button("Continue") {
                            Task {
                                await model.continueWithoutSaving(
                                    using: appState,
                                    dismiss: { dismiss() }
                                )
                            }
                        }
                        .controlSize(.large)
                        .disabled(model.isBusy)
                    }
                }
                .safeAreaPadding(.horizontal)
                .padding(.vertical)
                .safeAreaPadding(.bottom)
                .background(Color(.systemBackground))
            }
        }
        .trackKeyboardVisibility($isKeyboardVisible)
        .task {
            await model.prepare(using: appState)
        }
        .alert("Your avatar is public", isPresented: $showAvatarDisclosure) {
            Button("Continue") {
                switch pendingPhotoSource {
                case .photos:
                    showPhotoPicker = true
                case .files:
                    showFileImporter = true
                case nil:
                    break
                }
                pendingPhotoSource = nil
            }
            Button("Cancel", role: .cancel) {
                pendingPhotoSource = nil
            }
        } message: {
            Text("The photo is uploaded to a public service, and removing it from your profile may not delete the uploaded copy.")
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoLibraryPickerView(
                selectionLimit: 1,
                filter: .images,
                onSelection: { selections in
                    guard let selection = selections.first else { return }
                    cropSource = AvatarImageCropSource(
                        data: selection.data,
                        fileName: selection.fileName,
                        typeIdentifier: selection.typeIdentifier,
                        sourceURL: nil
                    )
                },
                onError: model.setAvatarPreparationError,
                onDismiss: { showPhotoPicker = false }
            )
            .ignoresSafeArea()
        }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            prepareImportedFile(result)
        }
        .sheet(isPresented: $showWebImagePicker) {
            OnboardingAvatarWebImagePicker { url in
                prepareWebImage(url)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(item: $cropSource) { source in
            AvatarImageCropEditor(source: source) { source, croppedData in
                Task {
                    await model.prepareAvatar(
                        data: croppedData,
                        fileName: source.fileName,
                        typeIdentifier: "public.jpeg"
                    )
                }
            }
        }
        .background {
            Color(.systemBackground)
                .ignoresSafeArea()
        }
    }

    private var avatarSection: some View {
        VStack(spacing: 0) {
            OnboardingAvatarPreview(
                name: model.displayName,
                image: model.avatarDraft?.thumbnail
            )
            .containerRelativeFrame(.horizontal, count: 3, span: 1, spacing: 0)

            Menu {
                Button {
                    requestPhotoSource(.photos)
                } label: {
                    Label("Choose from Photos", systemImage: "photo.on.rectangle")
                }

                Button {
                    requestPhotoSource(.files)
                } label: {
                    Label("Choose from Files", systemImage: "folder")
                }

                Button {
                    showWebImagePicker = true
                } label: {
                    Label("Find Image on Web", systemImage: "globe")
                }

                if model.avatarDraft != nil {
                    Divider()
                    Button("Remove Photo", systemImage: "trash", role: .destructive) {
                        model.setAvatarDraft(nil)
                    }
                }
            } label: {
                Text(model.avatarDraft == nil ? "Add Photo" : "Change Photo")
            }
            .wnAvatarActionButtonStyle()
            .padding(.top)
            .disabled(model.isPreparingAvatar)

            if model.isPreparingAvatar {
                ProgressView("Preparing Photo")
                    .font(.footnote)
                    .padding(.top)
            }

            if let avatarError = model.avatarError {
                Text(avatarError)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.top)
            }
        }
    }

    private var primaryActionTitle: String {
        if model.isSubmitting { return L10n.string("Signing Up…") }
        if model.phase == .creationFailed || model.phase == .profileSaveFailed {
            return L10n.string("Retry")
        }
        return L10n.string("Sign Up")
    }

    private var hasValidName: Bool {
        ContentSanitizer.displayName(model.displayName) != nil
    }

    private func requestPhotoSource(_ source: PendingPhotoSource) {
        pendingPhotoSource = source
        showAvatarDisclosure = true
    }

    private func prepareImportedFile(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await loadImportedFile(url) }
        case .failure(let error):
            model.setAvatarPreparationError(error)
        }
    }

    private func loadImportedFile(_ url: URL) async {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
        }
        do {
            let data = try await Task.detached(priority: .userInitiated) {
                try AvatarImageCropper.boundedFileData(from: url)
            }.value
            cropSource = AvatarImageCropSource(
                data: data,
                fileName: url.lastPathComponent,
                typeIdentifier: nil,
                sourceURL: url
            )
        } catch {
            model.setAvatarPreparationError(error)
        }
    }

    private func prepareWebImage(_ url: URL) {
        Task {
            do {
                let data = try await RemoteImageFetch.imageData(for: url)
                cropSource = AvatarImageCropSource(
                    data: data,
                    fileName: url.lastPathComponent,
                    typeIdentifier: nil,
                    sourceURL: url
                )
            } catch {
                model.setAvatarPreparationError(error)
            }
        }
    }
}
