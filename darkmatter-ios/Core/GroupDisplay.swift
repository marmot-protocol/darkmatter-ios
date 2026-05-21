import Foundation
import MarmotKit

/// Shared rules for how a group is titled and avatared across the chats list
/// and the conversation header. A named group shows its (sanitized) name; an
/// unnamed 2-member group renders as the other person; otherwise we fall back
/// to a shortened group id.
enum GroupDisplay {
    static func title(group: AppGroupRecordFfi, otherMember: String?, appState: AppState) -> String {
        if let name = ProfileSanitizer.groupName(group.name) { return name }
        if let other = otherMember { return appState.displayName(forAccountIdHex: other) }
        return IdentityFormatter.short(group.groupIdHex)
    }

    /// Avatar picture for the row/header — the other member's picture for an
    /// unnamed DM, otherwise none (the generated initials/color stand in).
    static func avatarURL(group: AppGroupRecordFfi, otherMember: String?, appState: AppState) -> URL? {
        guard ProfileSanitizer.groupName(group.name) == nil, let other = otherMember else { return nil }
        return appState.avatarURL(forAccountIdHex: other)
    }

    /// Deterministic color seed — keyed on the other member for an unnamed DM
    /// so their color matches wherever else they appear.
    static func avatarSeed(group: AppGroupRecordFfi, otherMember: String?) -> String {
        if group.name.isEmpty, let other = otherMember { return other }
        return group.groupIdHex
    }
}
