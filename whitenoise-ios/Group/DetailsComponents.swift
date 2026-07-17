import SwiftUI
import UIKit

/// Equal-width primary action for the details header rows (Add, Mute,
/// Search…). Icon over a short label, minimum 44-point target.
struct DetailsActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isDisabled = false
    var isLoading = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(.body.weight(.semibold))
                }
                Text(title)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.bordered)
        .disabled(isDisabled || isLoading)
    }
}

/// Tap-to-copy identity chip (npub, group id). Shows a transient copied
/// state; the value stays middle-truncated and monospaced.
struct CopyableIdentityChip: View {
    let display: String
    let copyValue: String
    let copiedToastTitle: String

    @State private var copied = false

    var body: some View {
        Button(action: copy) {
            HStack(spacing: 6) {
                Text(copied ? L10n.string("Copied") : display)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                    .lineLimit(1)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(copied ? Color.green : Color.accentColor)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.formatted("Copy %@", copiedToastTitle))
    }

    private func copy() {
        UIPasteboard.general.string = copyValue
        Haptics.selection()
        withAnimation(.smooth(duration: 0.15)) { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.smooth(duration: 0.2)) { copied = false }
        }
    }
}
