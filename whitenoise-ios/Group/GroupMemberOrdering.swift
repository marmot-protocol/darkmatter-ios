import Foundation
import MarmotKit

/// Deterministic member-list rules for group details: you first, then admins,
/// then everyone alphabetically by resolved name, with the member id as a
/// stable tiebreak so equal names can't reshuffle between renders.
nonisolated enum GroupMemberOrdering {
    static let previewCount = 6

    static func ordered(
        _ members: [GroupMemberDetailsFfi],
        namesByMemberId: [String: String]
    ) -> [GroupMemberDetailsFfi] {
        members.sorted { lhs, rhs in
            if lhs.isSelf != rhs.isSelf { return lhs.isSelf }
            if lhs.isAdmin != rhs.isAdmin { return lhs.isAdmin }
            let lhsName = folded(namesByMemberId[lhs.memberIdHex] ?? "")
            let rhsName = folded(namesByMemberId[rhs.memberIdHex] ?? "")
            if lhsName != rhsName { return lhsName < rhsName }
            return lhs.memberIdHex.lowercased() < rhs.memberIdHex.lowercased()
        }
    }

    /// Case- and diacritic-insensitive name filter, with an npub prefix match
    /// so a pasted key fragment still finds its member.
    static func filtered(
        _ members: [GroupMemberDetailsFfi],
        query: String,
        namesByMemberId: [String: String]
    ) -> [GroupMemberDetailsFfi] {
        let needle = folded(query)
        guard !needle.isEmpty else { return members }
        return members.filter { member in
            if folded(namesByMemberId[member.memberIdHex] ?? "").contains(needle) {
                return true
            }
            return member.npub.lowercased().hasPrefix(needle)
        }
    }

    /// Rows to show for the current expansion state: everything while
    /// searching or expanded, otherwise the preview slice.
    static func visible(
        _ members: [GroupMemberDetailsFfi],
        isSearching: Bool,
        isExpanded: Bool
    ) -> [GroupMemberDetailsFfi] {
        guard !isSearching, !isExpanded, members.count > previewCount else { return members }
        return Array(members.prefix(previewCount))
    }

    private static func folded(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
