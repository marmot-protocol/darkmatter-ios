import SwiftUI

/// Inline system-style row in the conversation timeline.
struct SystemEventRow: View {
    let event: SystemEvent

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
    }

    private var text: String {
        switch event {
        case .groupCreated: L10n.string("Chat created")
        case .groupRenamed(let new): L10n.formatted("Renamed to %@", new)
        case .groupArchived: L10n.string("Chat archived")
        case .groupUnarchived: L10n.string("Chat unarchived")
        case .rosterChanged: L10n.string("Membership changed")
        }
    }

}
