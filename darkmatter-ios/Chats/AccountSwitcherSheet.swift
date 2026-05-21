import SwiftUI
import MarmotKit

/// Account picker presented from the Chats toolbar avatar. Tapping a row
/// switches the active account; the trailing QR icon opens that account's
/// shareable profile-code screen.
struct AccountSwitcherSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var qrAccount: QRAccount?

    struct QRAccount: Identifiable {
        let hex: String
        var id: String { hex }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(appState.accounts, id: \.label) { account in
                        HStack(spacing: 12) {
                            Button {
                                appState.activeAccountRef = account.label
                                Haptics.selection()
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    AvatarBubble(
                                        seed: account.accountIdHex,
                                        title: appState.displayName(forAccountIdHex: account.accountIdHex),
                                        pictureURL: appState.avatarURL(forAccountIdHex: account.accountIdHex)
                                    )
                                    .frame(width: 40, height: 40)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(appState.displayName(forAccountIdHex: account.accountIdHex))
                                            .font(.body.weight(.medium))
                                            .foregroundStyle(.primary)
                                        Text(appState.shortNpub(forAccountIdHex: account.accountIdHex))
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }

                                    Spacer(minLength: 4)

                                    if account.label == appState.activeAccountRef {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    }
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)

                            Button {
                                qrAccount = QRAccount(hex: account.accountIdHex)
                            } label: {
                                Image(systemName: "qrcode")
                                    .font(.body)
                                    .foregroundStyle(.tint)
                                    .padding(.leading, 4)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Show profile QR code")
                        }
                    }
                }

                Section {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle("Accounts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(item: $qrAccount) { account in
                ProfileQRView(accountIdHex: account.hex)
            }
        }
    }
}
