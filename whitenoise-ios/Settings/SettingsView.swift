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

    var body: some View {
        Form {
            Section("Profile") {
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

                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
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
                        .controlSize(.regular)
                    }
                    .padding(.vertical, 2)
                }

                NavigationLink {
                    ProfileEditView()
                } label: {
                    Label("Edit Profile", systemImage: "person.crop.circle")
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
                    KeyPackagesView()
                } label: {
                    Label("Key Packages", systemImage: "key.icloud.fill")
                }

                NavigationLink {
                    PrivacySecuritySettingsView()
                } label: {
                    Label("Privacy & Security", systemImage: "hand.raised.fill")
                }
            }

            Section {
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

            Section {
                Button {
                    showAccountActions = true
                } label: {
                    HStack {
                        Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        Spacer()
                        Image(systemName: "chevron.up")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .disabled(appState.activeAccount == nil)
            } header: {
                Text("Account")
            } footer: {
                Text("Sign out while keeping this profile on the device, or permanently remove its local data.")
                    .font(.footnote)
            }
        }
        .trueBlackScaffoldBackground()
        .localizedNavigationTitle("Settings")
        .task(id: appState.activeAccount?.accountIdHex) {
            guard let id = appState.activeAccount?.accountIdHex else { return }
            await appState.reloadProfileProjection(forAccountIdHex: id)
        }
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
            List {
                Section {
                    actionButton(
                        title: "Sign Out",
                        description: "Keep this profile's keys, messages, media, and settings on this device.",
                        systemImage: "rectangle.portrait.and.arrow.right",
                        role: nil
                    ) {
                        showSignOutConfirmation = true
                    }

                    actionButton(
                        title: "Sign Out & Wipe",
                        description: "Permanently remove this profile and its local data from this device.",
                        systemImage: "trash.fill",
                        role: .destructive,
                        action: onWipe
                    )
                }
            }
            .navigationTitle("Sign Out")
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
                Button("Sign Out", role: .destructive, action: onSignOut)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You can sign back in without importing your keys again.")
            }
        }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isBusy)
    }

    private func actionButton(
        title: LocalizedStringKey,
        description: LocalizedStringKey,
        systemImage: String,
        role: ButtonRole?,
        action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.body.weight(.semibold))
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                if isBusy {
                    ProgressView()
                }
            }
            .padding(.vertical, 6)
        }
        .disabled(isBusy)
    }
}
