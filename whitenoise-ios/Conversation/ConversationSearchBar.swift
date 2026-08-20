import SwiftUI

/// Search entry pinned under the conversation header. Result navigation lives
/// in `ConversationSearchControls`, where the composer normally sits.
struct ConversationSearchBar: View {
    @Bindable var search: ConversationSearchModel
    let onClose: () -> Void

    @FocusState private var isFieldFocused: Bool

    @ScaledMetric(relativeTo: .body)
    private var closeIconSize: CGFloat = 18

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField("", text: $search.query, prompt: Text(L10n.string("Search messages")))
                    .textFieldStyle(.plain)
                    .font(.body)
                    .submitLabel(.search)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isFieldFocused)
                if !search.query.isEmpty {
                    Button {
                        search.query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .frame(minHeight: 46)
            .background(.regularMaterial, in: .capsule)
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }

            closeButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .onAppear {
            // Focus lands after the inset has been laid out, mirroring the
            // chat-list search field's deferred focus.
            Task { @MainActor in
                await Task.yield()
                isFieldFocused = true
            }
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: closeIconSize, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: .circle)
                .overlay {
                    Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close search")
    }
}

struct ConversationSearchControls: View {
    @Bindable var search: ConversationSearchModel

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                HStack(spacing: 0) {
                    searchButton(
                        systemImage: "chevron.up",
                        accessibilityLabel: "Previous match",
                        disabled: !search.canGoToOlderMatch || search.isPagingOlder
                    ) {
                        Task { await search.goToOlderMatch() }
                    }
                    searchButton(
                        systemImage: "chevron.down",
                        accessibilityLabel: "Next match",
                        disabled: !search.canGoToNewerMatch || search.isPagingOlder
                    ) {
                        search.goToNewerMatch()
                    }
                }
                .background(.regularMaterial, in: .capsule)
                .overlay {
                    Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }

                Spacer(minLength: 8)

                if search.hasQuery {
                    resultCount
                        .padding(.horizontal, 18)
                        .frame(minHeight: 44)
                        .background(.regularMaterial, in: .capsule)
                        .overlay {
                            Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        }
                }
            }

            if search.showsOlderContinuation {
                olderContinuationRow
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var resultCount: some View {
        if let position = search.displayPosition {
            Text(L10n.formatted("%1$lld of %2$lld", Int64(position), Int64(search.matches.count)))
                .contentTransition(.numericText())
        } else {
            Text(L10n.string("No matches"))
        }
    }

    private func searchButton(
        systemImage: String,
        accessibilityLabel: LocalizedStringKey,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(accessibilityLabel)
    }

    private var olderContinuationRow: some View {
        Button {
            Task { await search.searchOlder() }
        } label: {
            HStack(spacing: 6) {
                if search.isPagingOlder {
                    ProgressView()
                        .controlSize(.mini)
                }
                Text(L10n.string("Search older messages"))
                    .font(.footnote.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: 38)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .disabled(search.isPagingOlder)
    }
}
