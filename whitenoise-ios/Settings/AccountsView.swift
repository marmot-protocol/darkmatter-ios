import SwiftUI
import MarmotKit

struct AccountsView: View {
    @Environment(AppState.self) private var appState
    @State private var showAdd = false

    var body: some View {
        Form {
            Section {
                Button {
                    showAdd = true
                } label: {
                    Label("Add Profile", systemImage: "plus.circle.fill")
                }
            }

            Section {
                ForEach(appState.accounts, id: \.label) { account in
                    Button {
                        Task { await appState.activateAccount(account.label) }
                    } label: {
                        AccountSummaryRow(account: account)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Profiles")
        .navigationBarTitleDisplayMode(.inline)
        .task { await appState.refreshAccountUnreadSummaries() }
        .sheet(isPresented: $showAdd) {
            NavigationStack {
                WelcomeView()
            }
            .appAppearance()
        }
        // Close the add-account sheet as soon as a new identity lands, so the
        // user returns straight to the (updated) accounts list rather than
        // being left on the creation flow.
        .onChange(of: appState.accounts.count) { _, _ in
            if showAdd { showAdd = false }
        }
    }

    /// The unread count a Profiles row shows for an account, or `nil` when the
    /// badge should be hidden — no summary yet, or nothing unread.
    static func unreadBadgeCount(for summary: AccountUnreadFfi?) -> UInt64? {
        guard let summary, summary.hasUnread else { return nil }
        return max(summary.unreadCount, 1)
    }
}

struct AccountSummaryRow: View {
    @Environment(AppState.self) private var appState
    let account: AccountSummaryFfi

    var body: some View {
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
            Spacer()
            HStack(spacing: 8) {
                if let unreadCount = appState.accountUnreadBadgeCount(
                    forAccountIdHex: account.accountIdHex
                ) {
                    UnreadCountBadge(count: unreadCount)
                }
                if account.label == appState.activeAccountRef {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    } else if account.signedOut {
                        Text(L10n.string("Signed out"))
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.secondary)
                } else if !account.localSigning {
                    Text("Read-only")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.gray.opacity(0.18), in: Capsule())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    static func unreadBadgeCount(for summary: AccountUnreadFfi?) -> UInt64? {
        AccountsView.unreadBadgeCount(for: summary)
    }
}

struct SignedOutProfilesView: View {
    @Environment(AppState.self) private var appState
    @State private var showAdd = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 42, weight: .medium))
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text("Choose a profile")
                            .font(.title2.weight(.bold))
                        Text("Sign in to a profile stored on this device, or add a new one.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .listRowBackground(Color.clear)
                }

                Section("Profiles") {
                    ForEach(appState.accounts, id: \.label) { account in
                        Button {
                            Task { await appState.activateAccount(account.label) }
                        } label: {
                            AccountSummaryRow(account: account)
                        }
                        .buttonStyle(.plain)
                        .disabled(appState.isAccountExitInProgress)
                    }
                }

                Section {
                    Button {
                        showAdd = true
                    } label: {
                        Label("Add Profile", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("White Noise")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await appState.refreshAccountUnreadSummaries() }
        .sheet(isPresented: $showAdd) {
            NavigationStack {
                WelcomeView()
            }
            .appAppearance()
        }
        .onChange(of: appState.accounts.count) { _, _ in
            if showAdd { showAdd = false }
        }
    }
}
