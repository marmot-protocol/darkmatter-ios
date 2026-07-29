import SwiftUI
import MarmotKit

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @State private var showQR = false
    @State private var showProfileEdit = false
    @State private var showAccounts = false
    @State private var showAccountActions = false
    @State private var presentWipeAfterActionsDismiss = false
    @State private var wipeModel = SignOutAndWipeModel()
    @State private var supportChatModel = SupportChatViewModel()
    @State private var supportChatRequestID: UUID?

    var body: some View {
        Form {
            Section {
                if let active = appState.activeAccount {
                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            Button {
                                showProfileEdit = true
                            } label: {
                                HStack(spacing: 12) {
                                    AvatarBubble(
                                        seed: active.accountIdHex,
                                        title: appState.displayName(forAccountIdHex: active.accountIdHex),
                                        pictureURL: appState.avatarURL(forAccountIdHex: active.accountIdHex)
                                    )
                                    .frame(width: 44, height: 44)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(appState.displayName(forAccountIdHex: active.accountIdHex))
                                            .font(.headline)
                                        Text(appState.shortNpub(forAccountIdHex: active.accountIdHex))
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)

                            Button {
                                showQR = true
                            } label: {
                                Image(systemName: "qrcode")
                                    .font(.title3)
                                    .foregroundStyle(.tint)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("My QR code")
                        }

                        Button {
                            showAccounts = true
                        } label: {
                            HStack(spacing: 6) {
                                Text("Switch Profile")
                                Image(systemName: "arrow.up.arrow.down")
                            }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                    .padding(.vertical, 2)
                }

                NavigationLink {
                    IdentityView()
                } label: {
                    Label("Profile keys", systemImage: "key.fill")
                }

                NavigationLink {
                    RelaysView()
                } label: {
                    Label("Relays", systemImage: "antenna.radiowaves.left.and.right")
                }

                NavigationLink {
                    KeyPackagesView()
                } label: {
                    Label("Key Packages", systemImage: "key.icloud.fill")
                }

                Button {
                    showAccountActions = true
                } label: {
                    HStack {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                            .foregroundStyle(.red)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color(uiColor: .tertiaryLabel))
                    }
                }
                .disabled(appState.activeAccount == nil)
            } header: {
                Text("Profile")
            } footer: {
                Text("Sign out while keeping this profile on the device, or permanently remove its local data.")
                    .font(.footnote)
            }

            Section("App") {
                NavigationLink {
                    AppearanceSettingsView()
                } label: {
                    Label("Appearance", systemImage: "paintbrush.fill")
                }

                NavigationLink {
                    DataAndStorageView()
                } label: {
                    Label("Data and storage", systemImage: "arrow.up.arrow.down.circle.fill")
                }

                NavigationLink {
                    NotificationSettingsView()
                } label: {
                    Label("Notifications", systemImage: "bell.badge.fill")
                }

                NavigationLink {
                    PrivacySecuritySettingsView()
                } label: {
                    Label("Privacy & Security", systemImage: "hand.raised.fill")
                }
            }

            Section("Support") {
                Button {
                    supportChatRequestID = UUID()
                } label: {
                    HStack {
                        Label("Chat with support", systemImage: "message.fill")
                        Spacer()
                        if supportChatModel.phase == .loading
                            || supportChatModel.phase == .routing {
                            ProgressView()
                        }
                    }
                }
                .disabled(
                    supportChatModel.phase == .loading
                        || supportChatModel.phase == .routing
                )
                .buttonStyle(.plain)

                NavigationLink {
                    DonateView()
                } label: {
                    Label("Donate", systemImage: "heart.fill")
                }
            }

            Section("About") {
                LabeledContent("Version") {
                    Text(appVersion)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    Text("Built on")
                    Spacer(minLength: 8)
                    Text(marmotBuildLabel)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .allowsTightening(true)
                }
            }

        }
        .localizedNavigationTitle("Settings")
        .task(id: appState.activeAccount?.accountIdHex) {
            guard let id = appState.activeAccount?.accountIdHex else { return }
            await appState.reloadProfileProjection(forAccountIdHex: id)
        }
        .task(id: supportChatRequestID) {
            guard supportChatRequestID != nil else { return }
            await supportChatModel.start(using: appState) {
                appState.presentChat(groupIdHex: $0)
            }
        }
        .alert(
            SupportChatPresentation.failureTitle,
            isPresented: supportFailureBinding
        ) {
            Button("Try Again") {
                supportChatRequestID = UUID()
            }
            Button("Cancel", role: .cancel) {
                supportChatModel.dismissFailure()
            }
        } message: {
            Text(SupportChatPresentation.failureMessage)
        }
        .interactiveDismissDisabled(supportChatModel.isCreatingChat)
        .navigationDestination(isPresented: $showProfileEdit) {
            ProfileEditView()
        }
        .navigationDestination(isPresented: $showAccounts) {
            AccountsView()
        }
        .sheet(isPresented: $showQR) {
            if let hex = appState.activeAccount?.accountIdHex {
                ProfileQRView(accountIdHex: hex)
            }
        }
        .sheet(isPresented: $showAccountActions, onDismiss: {
            guard presentWipeAfterActionsDismiss else { return }
            presentWipeAfterActionsDismiss = false
            wipeModel.present()
        }) {
            AccountActionsSheet(
                isBusy: appState.isAccountExitInProgress,
                onSignOut: {
                    Task { @MainActor in
                        if await appState.signOut() {
                            showAccountActions = false
                            dismiss()
                        }
                    }
                },
                onWipe: {
                    presentWipeAfterActionsDismiss = true
                    showAccountActions = false
                }
            )
            .appAppearance()
        }
        .fullScreenCover(isPresented: $wipeModel.isPresented) {
            SignOutAndWipeCover(
                model: wipeModel,
                onConfirm: { wipeModel.confirmWipe(using: appState) },
                onCancel: { wipeModel.cancel() }
            )
            .appAppearance()
        }
        .onChange(of: appState.activeAccountRef) { oldValue, newValue in
            if oldValue != nil, oldValue != newValue {
                dismiss()
            }
        }
    }

    private var appVersion: String {
        let dict = Bundle.main.infoDictionary
        let version = dict?["CFBundleShortVersionString"] as? String ?? "—"
        let build = dict?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    private var supportFailureBinding: Binding<Bool> {
        Binding(
            get: { supportChatModel.phase == .failed },
            set: { isPresented in
                if !isPresented {
                    supportChatModel.dismissFailure()
                }
            }
        )
    }

    private var marmotBuildLabel: String {
        // Compile-time constant regenerated by sync-bindings.sh; always
        // present (the MARMOT_VERSION text file isn't bundled into the app).
        MarmotKitBuildLabel.text(
            tag: MarmotKitVersion.mdkTag,
            sha: MarmotKitVersion.mdkSHA
        )
    }
}

nonisolated enum MarmotKitBuildLabel {
    static func text(tag: String, sha: String) -> String {
        let isSourceBuild = sha.hasSuffix("-dirty")
        let shortHash = sha
            .replacingOccurrences(of: "-dirty", with: "")
            .prefix(8)

        if !isSourceBuild, let version = version(from: tag) {
            return "MarmotKit v\(version) (\(shortHash))"
        }
        return "MarmotKit (\(shortHash))"
    }

    private static func version(from tag: String) -> Substring? {
        let prefix = "marmotkit-v"
        guard tag.hasPrefix(prefix) else { return nil }
        let version = tag.dropFirst(prefix.count)
        return version.isEmpty ? nil : version
    }
}

private struct AccountActionsSheet: View {
    let isBusy: Bool
    let onSignOut: () -> Void
    let onWipe: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var showSignOutConfirmation = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    actionBlock(
                        title: "Sign Out",
                        description: "Keep this profile's keys, messages, media, and settings on this device.",
                        systemImage: "rectangle.portrait.and.arrow.right",
                        tint: .accentColor
                    ) {
                        showSignOutConfirmation = true
                    }

                    actionBlock(
                        title: "Sign Out & Wipe",
                        description: "Permanently remove this profile and its local data from this device.",
                        systemImage: "trash.fill",
                        tint: .red,
                        action: onWipe
                    )
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 28)
            }
            .localizedNavigationTitle("Sign Out")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isBusy)
                }
            }
            .confirmationDialog(
                "Sign out of this profile?",
                isPresented: $showSignOutConfirmation,
                titleVisibility: .visible
            ) {
                Button("Sign Out", action: onSignOut)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You can sign back in without importing your keys again.")
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isBusy)
    }

    private func actionBlock(
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: action) {
                HStack(spacing: 10) {
                    if isBusy {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: systemImage)
                    }
                    Text(title)
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(tint)
            .foregroundStyle(.white)
            .disabled(isBusy)

            Text(description)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
        }
    }
}
