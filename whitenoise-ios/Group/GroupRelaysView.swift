import SwiftUI

/// Read-only delivery relay details for a conversation. MDK owns group relay
/// selection, so this surface deliberately does not imply that editing the
/// account relay list would mutate an existing group's routing.
struct GroupRelaysView: View {
    let relays: [String]

    private var rows: [String] {
        GroupRelaysPresentation.rows(for: relays)
    }

    var body: some View {
        Form {
            Section {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, relay in
                    HStack(spacing: 12) {
                        Image(systemName: "network")
                            .foregroundStyle(.secondary)
                            .frame(width: 28, height: 28)

                        Text(relay)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(
                                relay == GroupRelaysPresentation.emptyMessage ? .secondary : .primary
                            )
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .navigationTitle("Relays")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
    }
}
