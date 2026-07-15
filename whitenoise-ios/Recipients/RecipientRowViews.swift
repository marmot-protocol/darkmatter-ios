import SwiftUI
import UIKit
import MarmotKit

/// One person in a recipient list: avatar, resolved name, and identity
/// context (NIP-05 when the profile declares a shape-valid one, otherwise the
/// short npub). The trailing slot carries selection or progress state.
struct RecipientRow<Trailing: View>: View {
    @Environment(AppState.self) private var appState
    let accountIdHex: String
    let npub: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            AvatarBubble(
                seed: accountIdHex,
                title: displayName,
                pictureURL: appState.avatarURL(forAccountIdHex: accountIdHex)
            )
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                    .font(.body)
                    .lineLimit(1)
                Text(secondaryIdentity)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var displayName: String {
        appState.knownDisplayName(forAccountIdHex: accountIdHex)
            ?? IdentityFormatter.short(npub)
    }

    private var secondaryIdentity: String {
        if let nip05 = ContentSanitizer.profileAddress(
            appState.profile(forAccountIdHex: accountIdHex)?.nip05
        ) {
            return nip05
        }
        return IdentityFormatter.short(npub)
    }
}

/// Selection state for multi-select recipient rows.
struct RecipientSelectionIndicator: View {
    let isSelected: Bool

    var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
            .accessibilityHidden(true)
    }
}

/// Removable horizontal rail of the currently selected people.
struct SelectedRecipientRail: View {
    @Environment(AppState.self) private var appState
    let members: [MemberRefFfi]
    let onRemove: (MemberRefFfi) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(members, id: \.accountIdHex) { member in
                    railChip(for: member)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
        .animation(.snappy(duration: 0.2), value: members.map(\.accountIdHex))
    }

    private func railChip(for member: MemberRefFfi) -> some View {
        let name = appState.knownDisplayName(forAccountIdHex: member.accountIdHex)
            ?? IdentityFormatter.short(member.npub)
        return Button {
            onRemove(member)
        } label: {
            VStack(spacing: 4) {
                AvatarBubble(
                    seed: member.accountIdHex,
                    title: name,
                    pictureURL: appState.avatarURL(forAccountIdHex: member.accountIdHex)
                )
                .frame(width: 52, height: 52)
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color(.systemBackground), Color.secondary)
                        .offset(x: 4, y: -4)
                }
                Text(name)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(maxWidth: 64)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.formatted("Remove %@", name))
    }
}

/// Quick action rows shown above the people list (New Group, Scan QR Code,
/// Show My QR Code).
struct RecipientQuickActionRow: View {
    let title: LocalizedStringKey
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.body)
                    .foregroundStyle(.tint)
                    .frame(width: 28)
                Text(title)
                    .font(.body)
                Spacer(minLength: 0)
            }
            .frame(minHeight: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// Search field for recipient screens: magnifier, the query, and a paste
/// affordance while empty (a clear button once text is present). Pasting
/// feeds the same query pipeline as typing.
struct RecipientSearchField: View {
    @Binding var text: String
    var placeholder: LocalizedStringKey = "Search or paste npub"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .font(.body)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if text.isEmpty {
                Button {
                    if let pasted = UIPasteboard.general.string?
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                        !pasted.isEmpty {
                        text = pasted
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.callout)
                        .foregroundStyle(.tint)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Paste")
            } else {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(.tertiarySystemFill), in: .rect(cornerRadius: 10))
    }
}

/// Placeholder row while an identifier query resolves against Marmot or a
/// NIP-05 host.
struct RecipientResolvingRow: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .frame(width: 44, height: 44)
            Text("Resolving…")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
