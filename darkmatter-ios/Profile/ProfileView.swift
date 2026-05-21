import SwiftUI
import MarmotKit

/// Read-only profile shown when you scan someone's QR or open a profile deep
/// link. Resolves the npub to an account id, enriches with cached/fetched
/// kind:0 metadata, and offers a "Message" action that starts a 2-member
/// group with them.
struct ProfileView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let npub: String

    @State private var hex: String?
    @State private var creating = false
    @State private var error: String?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Spacer(minLength: 12)

                AvatarBubble(
                    seed: hex ?? npub,
                    title: title,
                    pictureURL: hex.flatMap { appState.avatarURL(forAccountIdHex: $0) }
                )
                .frame(width: 96, height: 96)

                Text(title)
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                Button(action: copyNpub) {
                    HStack(spacing: 8) {
                        Text(copied ? "Copied" : IdentityFormatter.short(npub))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(copied ? Color.green : Color.secondary)
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(copied ? Color.green : Color.accentColor)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                if hex == nil {
                    Label("Couldn't read this profile code.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal, 24)
                }

                Button {
                    Task { await message() }
                } label: {
                    HStack {
                        if creating { ProgressView().controlSize(.small) }
                        Label("Message", systemImage: "bubble.left.and.bubble.right.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 24)
                .disabled(creating || hex == nil || appState.activeAccountRef == nil || isSelf)
            }
            .padding(.bottom, 16)
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await resolve() }
        }
    }

    private var title: String {
        if let hex { return appState.displayName(forAccountIdHex: hex) }
        return IdentityFormatter.short(npub)
    }

    private var isSelf: Bool {
        guard let hex else { return false }
        return appState.accounts.contains { $0.accountIdHex == hex }
    }

    @MainActor
    private func resolve() async {
        hex = appState.marmot.accountIdHex(reference: npub)
        if let hex {
            // Trigger enrichment (cached read + background relay fetch).
            _ = appState.profile(forAccountIdHex: hex)
        }
    }

    private func copyNpub() {
        UIPasteboard.general.string = npub
        Haptics.selection()
        withAnimation(.smooth(duration: 0.15)) { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.smooth(duration: 0.2)) { copied = false }
        }
    }

    @MainActor
    private func message() async {
        guard let accountRef = appState.activeAccountRef else { return }
        creating = true
        error = nil
        do {
            _ = try await appState.marmot.createGroup(
                accountRef: accountRef,
                name: "",
                memberRefs: [npub],
                description: nil
            )
            Haptics.success()
            appState.present(.success("Chat started"))
            dismiss()
        } catch {
            Haptics.error()
            self.error = error.localizedDescription
        }
        creating = false
    }
}
