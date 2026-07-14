import SwiftUI

/// The in-conversation search bar pinned under the navigation bar: query
/// field, match counter, previous/next match navigation, and the budgeted
/// "Search older messages" continuation.
struct ConversationSearchBar: View {
    @Bindable var search: ConversationSearchModel
    let onClose: () -> Void

    @FocusState private var isFieldFocused: Bool

    @ScaledMetric(relativeTo: .body)
    private var closeIconSize: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
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
                counter
                navigationButtons
                closeButton
            }
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            if search.showsOlderContinuation {
                olderContinuationRow
            }
        }
        .background(.bar)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .onAppear {
            // Focus lands after the inset has been laid out, mirroring the
            // chat-list search field's deferred focus.
            Task { @MainActor in
                await Task.yield()
                isFieldFocused = true
            }
        }
    }

    @ViewBuilder
    private var counter: some View {
        if search.hasQuery {
            if let position = search.displayPosition {
                Text(L10n.formatted("%1$lld of %2$lld", Int64(position), Int64(search.matches.count)))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            } else {
                Text(L10n.string("No matches"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    private var navigationButtons: some View {
        HStack(spacing: 0) {
            Button {
                Task { await search.goToOlderMatch() }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!search.canGoToOlderMatch || search.isPagingOlder)
            .accessibilityLabel("Previous match")

            Button {
                search.goToNewerMatch()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .frame(width: 34, height: 34)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!search.canGoToNewerMatch || search.isPagingOlder)
            .accessibilityLabel("Next match")
        }
        .foregroundStyle(.primary)
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: closeIconSize))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close search")
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
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
        .disabled(search.isPagingOlder)
    }
}
