import SwiftUI
import PhotosUI

/// Generate a brand-new Nostr identity. The keypair is created and stored in
/// the iOS Keychain inside marmot-app; we never see the nsec in Swift.
///
/// On success the parent routes automatically: during onboarding the app
/// advances to the main UI; when adding an account, the Accounts sheet
/// dismisses back to the accounts list. There's no intermediate "created"
/// screen.
struct CreateIdentityView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var model = CreateIdentityViewModel()
    @State private var showAvatarDisclosure = false
    @State private var showPhotoPicker = false
    @State private var cropSource: AvatarImageCropSource?

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                VStack(spacing: 12) {
                    AvatarBubble(
                        seed: model.displayName.isEmpty ? "new-profile" : model.displayName,
                        title: model.displayName.isEmpty
                            ? L10n.string("New profile")
                            : model.displayName,
                        pictureImage: model.avatarDraft?.thumbnail
                    )
                    .frame(width: 80, height: 80)
                    .overlay {
                        if model.isPreparingAvatar {
                            ProgressView()
                        }
                    }
                    .accessibilityLabel(
                        model.avatarDraft == nil
                            ? L10n.string("Profile avatar preview")
                            : L10n.string("Selected profile photo")
                    )

                    if model.avatarDraft == nil {
                        Button("Choose Avatar") {
                            showAvatarDisclosure = true
                        }
                    } else {
                        Button("Change Avatar") {
                            showAvatarDisclosure = true
                        }
                        Button("Remove Avatar", role: .destructive) {
                            model.setAvatarDraft(nil)
                        }
                    }
                }
                .disabled(model.isPreparingAvatar)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if let avatarError = model.avatarError {
                    Label(avatarError, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("Profile") {
                TextField("Name", text: $model.displayName)
                    .textContentType(.name)
                TextField("About (Optional)", text: $model.about, axis: .vertical)
                    .lineLimit(2...5)
            }

            if let failureMessage = model.failureMessage {
                Section {
                    Label(failureMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
        }
        .disabled(model.isSubmitting)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                Button {
                    Task {
                        if model.phase == .creationFailed {
                            await model.prepare(using: appState)
                        } else {
                            await model.submit(using: appState, dismiss: { dismiss() })
                        }
                    }
                } label: {
                    HStack {
                        if model.isBusy {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(primaryActionTitle)
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.isBusy)
                .accessibilityLabel(primaryActionTitle)

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
            .padding()
            .background(.bar)
        }
        .navigationTitle("Sign Up")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(!model.allowsBackNavigation)
        .interactiveDismissDisabled(!model.allowsBackNavigation)
        .task {
            await model.prepare(using: appState)
        }
        .alert("Choose Avatar", isPresented: $showAvatarDisclosure) {
            Button("Continue") {
                showPhotoPicker = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Your avatar is public. The photo is uploaded to a public service, and removing it from your profile may not delete the uploaded copy."
            )
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
                onDismiss: {
                    showPhotoPicker = false
                }
            )
            .ignoresSafeArea()
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
    }

    private var primaryActionTitle: String {
        if model.isSubmitting {
            return L10n.string("Signing Up…")
        }
        if model.phase == .creationFailed || model.phase == .profileSaveFailed {
            return L10n.string("Retry")
        }
        return L10n.string("Sign Up")
    }
}
