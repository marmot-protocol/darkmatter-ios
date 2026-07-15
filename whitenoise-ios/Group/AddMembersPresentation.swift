import Foundation
import MarmotKit

nonisolated enum AddMembersPresentation {
    enum PendingMemberAddResult: Equatable {
        case empty
        case invalid
        case duplicate
        case blocked
        case added([MemberRefFfi], MemberRefFfi)
    }

    /// Outcome of normalizing a raw member reference off the main actor,
    /// before it is staged against the live member list.
    enum NormalizedMemberResult: Equatable {
        case empty
        case invalid
        case normalized(MemberRefFfi)
    }

    /// True when `raw` already parses to a complete, valid profile reference
    /// (npub/nprofile with a good checksum, or 64-char hex). Synchronous — no
    /// Marmot hop.
    static func isCompleteReference(_ raw: String) -> Bool {
        memberRef(fromScannedPayload: raw) != nil
    }

    static func memberRef(fromScannedPayload raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if case .profile(let memberRef) = DeepLink.parse(string: trimmed) {
            return memberRef
        }
        return NostrProfileReference.referenceForResolution(fromReference: trimmed)
    }

    /// Parses and normalizes a raw member reference. The `normalize` closure
    /// is expected to run the synchronous MarmotKit FFI off the main actor
    /// (#260), so callers can `await` this and only hop back to the MainActor
    /// to stage the result.
    static func normalizedMember(
        _ raw: String,
        normalize: (String) async throws -> MemberRefFfi
    ) async -> NormalizedMemberResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard let memberRef = memberRef(fromScannedPayload: trimmed) else {
            return .invalid
        }
        do {
            return .normalized(try await normalize(memberRef))
        } catch {
            return .invalid
        }
    }

    /// Stages a normalized member against the current member list. Pure and
    /// MainActor-cheap: callers run this after awaiting `normalizedMember` so
    /// the dedup check sees the live `members` value rather than a snapshot
    /// captured before the off-main hop.
    static func stage(
        _ normalized: MemberRefFfi,
        existingMembers: [MemberRefFfi],
        excludedAccountIds: Set<String> = []
    ) -> PendingMemberAddResult {
        let accountId = normalizedAccountId(normalized.accountIdHex)
        let blockedAccountIds = Set(excludedAccountIds.map(normalizedAccountId))
        guard !blockedAccountIds.contains(accountId) else {
            return .blocked
        }
        guard !existingMembers.contains(where: { normalizedAccountId($0.accountIdHex) == accountId }) else {
            return .duplicate
        }
        return .added(existingMembers + [normalized], normalized)
    }

    static let selfRecipientMessage = "You can't add yourself to a chat."
    static let existingMemberMessage = "That profile is already in this group."

    static func excludedNewChatAccountIds(activeAccountIdHex: String?) -> Set<String> {
        normalizedAccountSet([activeAccountIdHex])
    }

    static func excludedInviteAccountIds(
        activeAccountIdHex: String?,
        members: [AppGroupMemberRecordFfi],
        groupMemberDetails: [GroupMemberDetailsFfi]
    ) -> Set<String> {
        var accountIds = normalizedAccountSet([activeAccountIdHex])
        accountIds.formUnion(normalizedAccountSet(members.map(\.memberIdHex)))
        accountIds.formUnion(normalizedAccountSet(groupMemberDetails.map(\.memberIdHex)))
        return accountIds
    }

    /// "Create" is enabled once at least one member is staged, no create is
    /// in flight, and there is an active account to create the group under.
    static func canCreate(stagedCount: Int, isCreating: Bool, hasActiveAccount: Bool) -> Bool {
        stagedCount > 0 && !isCreating && hasActiveAccount
    }

    /// "Invite" is enabled when no invite is in flight and at least one
    /// person is selected.
    static func canInvite(stagedCount: Int, isInviting: Bool) -> Bool {
        !isInviting && stagedCount > 0
    }

    @MainActor
    static func displayName(for member: MemberRefFfi, appState: AppState) -> String {
        appState.knownDisplayName(forAccountIdHex: member.accountIdHex)
            ?? IdentityFormatter.short(member.accountIdHex)
    }

    static func secondaryIdentity(for member: MemberRefFfi) -> String {
        IdentityFormatter.short(member.npub)
    }

    private static func normalizedAccountSet(_ values: [String?]) -> Set<String> {
        Set(values.compactMap { value in
            value.map(normalizedAccountId).flatMap { $0.isEmpty ? nil : $0 }
        })
    }

    private static func normalizedAccountId(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
