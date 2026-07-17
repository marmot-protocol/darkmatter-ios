import Foundation
import MarmotKit

struct ComposerMentionCandidate: Identifiable, Equatable {
    let id: String
    let memberIdHex: String
    let displayName: String
    let npub: String
    let avatarPictureURL: URL?

    // Lowercased forms of the stable match fields, precomputed once at
    // construction. `filter` runs on every keystroke while composing a
    // mention; caching these avoids re-lowercasing/re-allocating per
    // candidate on the MainActor typing hot path (see issue #300).
    let displayNameLowercased: String
    let npubLowercased: String
    let memberIdHexLowercased: String

    init(details: GroupMemberDetailsFfi, appState: AppState) {
        memberIdHex = details.memberIdHex
        npub = details.npub
        let accountIdHex = GroupMemberDetailsPresentation.profileAccountIdHex(for: details)
        displayName =
            ContentSanitizer.displayName(details.displayName)
            ?? appState.knownDisplayName(forAccountIdHex: accountIdHex)
            ?? IdentityFormatter.short(accountIdHex)
        avatarPictureURL = appState.avatarURL(forAccountIdHex: accountIdHex)
        id = memberIdHex
        displayNameLowercased = displayName.lowercased()
        npubLowercased = npub.lowercased()
        memberIdHexLowercased = memberIdHex.lowercased()
    }

    init?(member: AppGroupMemberRecordFfi, appState: AppState) {
        guard !member.local else { return nil }
        let accountHex = member.account ?? member.memberIdHex
        guard let npub = NostrProfileReference.npub(fromAccountIdHex: accountHex)
        else { return nil }
        memberIdHex = member.memberIdHex
        self.npub = npub
        displayName = appState.displayName(forAccountIdHex: accountHex)
        avatarPictureURL = appState.avatarURL(forAccountIdHex: accountHex)
        id = memberIdHex
        displayNameLowercased = displayName.lowercased()
        npubLowercased = self.npub.lowercased()
        memberIdHexLowercased = memberIdHex.lowercased()
    }
}

enum ComposerMentionQuery {
    struct Session: Equatable {
        let atIndex: String.Index
        let query: String

        func replacementRange(in draft: String) -> Range<String.Index> {
            atIndex..<draft.endIndex
        }
    }

    static let maxVisibleCandidates = 8
    private static let completeNpubBodyLength = 58

    static func active(in draft: String) -> Session? {
        guard let atIndex = draft.lastIndex(of: "@") else { return nil }
        if atIndex > draft.startIndex {
            let before = draft[draft.index(before: atIndex)]
            guard before.isWhitespace || before.isNewline else { return nil }
        }
        let queryStart = draft.index(after: atIndex)
        guard queryStart <= draft.endIndex else { return nil }
        let query = String(draft[queryStart...])
        guard !query.contains(where: \.isWhitespace) else { return nil }
        guard !query.contains(where: \.isNewline) else { return nil }
        return Session(atIndex: atIndex, query: query)
    }

    static func looksLikeCompleteNpub(_ query: String) -> Bool {
        query.hasPrefix("npub1") && query.count >= 5 + completeNpubBodyLength
    }

    static func filter(_ candidates: [ComposerMentionCandidate], matching query: String)
        -> [ComposerMentionCandidate]
    {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered: [ComposerMentionCandidate]
        if trimmed.isEmpty {
            filtered = candidates
        } else {
            let needle = trimmed.lowercased()
            filtered = candidates.filter { candidate in
                candidate.displayNameLowercased.contains(needle)
                    || candidate.npubLowercased.contains(needle)
                    || candidate.memberIdHexLowercased.contains(needle)
            }
        }
        return Array(filtered.prefix(maxVisibleCandidates))
    }

    static func replacing(
        session: Session,
        in draft: String,
        with displayName: String
    ) -> String {
        var updated = draft
        updated.replaceSubrange(session.replacementRange(in: draft), with: "@\(displayName) ")
        return updated
    }
}

nonisolated struct ComposerMentionSelection: Equatable, Sendable {
    var utf16Location: Int
    let utf16Length: Int
    let displayName: String
    let npub: String
}

/// Keeps selected mention identities attached to the text occurrence the user
/// tapped. Edits outside a token shift its UTF-16 range; edits touching a token
/// discard the binding so ambiguous free text always fails closed.
nonisolated enum ComposerMentionSelectionTracker {
    static func reconcile(
        _ selections: [ComposerMentionSelection],
        from oldText: String,
        to newText: String
    ) -> [ComposerMentionSelection] {
        guard oldText != newText else {
            return selections.filter { selectionIsPresent($0, in: newText) }
        }

        let oldUnits = Array(oldText.utf16)
        let newUnits = Array(newText.utf16)
        var commonPrefix = 0
        while commonPrefix < oldUnits.count,
              commonPrefix < newUnits.count,
              oldUnits[commonPrefix] == newUnits[commonPrefix] {
            commonPrefix += 1
        }

        var commonSuffix = 0
        while commonSuffix < oldUnits.count - commonPrefix,
              commonSuffix < newUnits.count - commonPrefix {
            let oldIndex = oldUnits.count - commonSuffix - 1
            let newIndex = newUnits.count - commonSuffix - 1
            guard oldUnits[oldIndex] == newUnits[newIndex] else { break }
            commonSuffix += 1
        }

        let oldChangeEnd = oldUnits.count - commonSuffix
        let newChangeEnd = newUnits.count - commonSuffix
        let delta = newChangeEnd - oldChangeEnd

        return selections.compactMap { selection in
            let selectionEnd = selection.utf16Location + selection.utf16Length
            var adjusted = selection
            if selectionEnd <= commonPrefix {
                // The edit is entirely after this token.
            } else if selection.utf16Location >= oldChangeEnd {
                adjusted.utf16Location += delta
            } else {
                return nil
            }
            return selectionIsPresent(adjusted, in: newText) ? adjusted : nil
        }
    }

    private static func selectionIsPresent(_ selection: ComposerMentionSelection, in text: String) -> Bool {
        let units = Array(text.utf16)
        let end = selection.utf16Location + selection.utf16Length
        guard selection.utf16Location >= 0, end <= units.count else { return false }
        let token = String(decoding: units[selection.utf16Location..<end], as: UTF16.self)
        return token == "@\(selection.displayName)"
    }
}

nonisolated enum ComposerMentionCanonicalizer {
    private static let underscoreScalar = UnicodeScalar("_")
    private static let slashScalar = UnicodeScalar("/")

    static func canonicalize(
        _ text: String,
        candidates: [ComposerMentionCandidate],
        selectedMentions: [ComposerMentionSelection] = []
    ) -> String {
        guard text.contains("@") else { return text }
        let replacements = candidates
            .filter { candidate in
                !candidate.npub.isEmpty
                    && !candidate.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            .sorted { lhs, rhs in
                lhs.displayName.count > rhs.displayName.count
            }
        guard !replacements.isEmpty else { return text }

        var canonical = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "@",
               leftBoundaryAllowsMention(at: index, in: text),
               let match = matchCandidate(
                   in: text,
                   at: index,
                   candidates: replacements,
                   selectedMentions: selectedMentions
               ) {
                canonical += "@\(match.npub)"
                index = match.endIndex
                continue
            }
            canonical.append(text[index])
            index = text.index(after: index)
        }
        return canonical
    }

    private static func matchCandidate(
        in text: String,
        at atIndex: String.Index,
        candidates: [ComposerMentionCandidate],
        selectedMentions: [ComposerMentionSelection]
    ) -> (npub: String, endIndex: String.Index)? {
        let nameStart = text.index(after: atIndex)
        for candidate in candidates {
            guard text[nameStart...].hasPrefix(candidate.displayName) else { continue }
            let nameEnd = text.index(nameStart, offsetBy: candidate.displayName.count)
            guard rightBoundaryAllowsMention(at: nameEnd, in: text) else { continue }
            // The identity comes from what the user actually tapped, never
            // from a text race: with several members sharing this display
            // name, only an explicit selection resolves it — a peer cloning
            // a name cannot capture an unselected mention, it just stays
            // literal text.
            let sharingName = candidates.filter { $0.displayName == candidate.displayName }
            let distinctNpubs = Set(sharingName.map(\.npub))
            if distinctNpubs.count == 1 {
                return (candidate.npub, nameEnd)
            }
            let location = text[..<atIndex].utf16.count
            let length = "@\(candidate.displayName)".utf16.count
            if let selected = selectedMentions.first(where: {
                $0.utf16Location == location
                    && $0.utf16Length == length
                    && $0.displayName == candidate.displayName
                    && distinctNpubs.contains($0.npub)
            }) {
                return (selected.npub, nameEnd)
            }
            return nil
        }
        return nil
    }

    private static func leftBoundaryAllowsMention(at atIndex: String.Index, in text: String) -> Bool {
        if atIndex == text.startIndex { return true }
        let previous = text[text.index(before: atIndex)]
        return isNostrMentionBoundary(previous)
    }

    private static func rightBoundaryAllowsMention(at index: String.Index, in text: String) -> Bool {
        guard index < text.endIndex else { return true }
        return isNostrMentionBoundary(text[index])
    }

    private static func isNostrMentionBoundary(_ character: Character) -> Bool {
        !character.unicodeScalars.contains(where: { scalar in
            CharacterSet.alphanumerics.contains(scalar)
                || scalar == underscoreScalar
                || scalar == slashScalar
        })
    }
}

/// Identifies the inputs the cached `@`-mention candidate list was built from.
/// Both generations are monotonic: `rosterGeneration` bumps on group
/// membership/admin changes, `profileGeneration` bumps when resolved
/// display-name/avatar/npub data refreshes. A change in either invalidates the
/// cache so freshly resolved names still surface in autocomplete. Non-private so
/// the invalidation contract can be unit-tested (#300).
nonisolated struct MentionCandidateCacheKey: Equatable {
    let rosterGeneration: UInt64
    let profileGeneration: Int
}

/// Builds + caches the conversation's `@`-mention candidate list and applies a
/// selection back into the draft. Extracted from `ConversationViewModel`: it
/// reads the roster (passed per call) but owns no conversation state beyond the
/// keystroke-hot-path cache, which invalidates on roster/profile generation
/// changes (#300).
@MainActor
final class ComposerMentionController {
    private var cachedCandidates: [ComposerMentionCandidate]?
    private var cachedKey: MentionCandidateCacheKey?
    private(set) var selectedMentions: [ComposerMentionSelection] = []
    private var observedDraft: String?

    func candidates(
        for draft: String,
        appState: AppState?,
        members: [AppGroupMemberRecordFfi],
        groupMemberDetails: [GroupMemberDetailsFfi],
        rosterGeneration: UInt64
    ) -> [ComposerMentionCandidate] {
        synchronizeSelections(with: draft)
        guard let appState,
              let session = ComposerMentionQuery.active(in: draft),
              !ComposerMentionQuery.looksLikeCompleteNpub(session.query)
        else { return [] }
        return ComposerMentionQuery.filter(
            allCandidates(
                appState: appState,
                members: members,
                groupMemberDetails: groupMemberDetails,
                rosterGeneration: rosterGeneration
            ),
            matching: session.query
        )
    }

    func applySelection(_ candidate: ComposerMentionCandidate, to draft: inout String) {
        synchronizeSelections(with: draft)
        guard let session = ComposerMentionQuery.active(in: draft) else { return }
        let updated = ComposerMentionQuery.replacing(
            session: session,
            in: draft,
            with: candidate.displayName
        )
        selectedMentions = ComposerMentionSelectionTracker.reconcile(
            selectedMentions,
            from: draft,
            to: updated
        )
        if !candidate.npub.isEmpty {
            let location = draft[..<session.atIndex].utf16.count
            let length = "@\(candidate.displayName)".utf16.count
            let end = location + length
            selectedMentions.removeAll {
                max(location, $0.utf16Location) < min(end, $0.utf16Location + $0.utf16Length)
            }
            selectedMentions.append(ComposerMentionSelection(
                utf16Location: location,
                utf16Length: length,
                displayName: candidate.displayName,
                npub: candidate.npub
            ))
        }
        observedDraft = updated
        draft = updated
    }

    func clearSelections() {
        selectedMentions = []
        observedDraft = nil
    }

    func canonicalizeMentions(
        in text: String,
        appState: AppState?,
        members: [AppGroupMemberRecordFfi],
        groupMemberDetails: [GroupMemberDetailsFfi],
        rosterGeneration: UInt64
    ) -> String {
        synchronizeSelections(with: text)
        guard let appState else { return text }
        return ComposerMentionCanonicalizer.canonicalize(
            text,
            candidates: allCandidates(
                appState: appState,
                members: members,
                groupMemberDetails: groupMemberDetails,
                rosterGeneration: rosterGeneration
            ),
            selectedMentions: selectedMentions
        )
    }

    private func synchronizeSelections(with draft: String) {
        guard let observedDraft else {
            self.observedDraft = draft
            return
        }
        selectedMentions = ComposerMentionSelectionTracker.reconcile(
            selectedMentions,
            from: observedDraft,
            to: draft
        )
        self.observedDraft = draft
    }

    private func allCandidates(
        appState: AppState,
        members: [AppGroupMemberRecordFfi],
        groupMemberDetails: [GroupMemberDetailsFfi],
        rosterGeneration: UInt64
    ) -> [ComposerMentionCandidate] {
        let key = MentionCandidateCacheKey(
            rosterGeneration: rosterGeneration,
            profileGeneration: appState.profileRefreshGeneration
        )
        if let cachedCandidates, cachedKey == key {
            return cachedCandidates
        }
        let candidates: [ComposerMentionCandidate]
        if !groupMemberDetails.isEmpty {
            candidates = groupMemberDetails
                .filter { !$0.isSelf }
                .map { ComposerMentionCandidate(details: $0, appState: appState) }
        } else {
            candidates = members.compactMap { ComposerMentionCandidate(member: $0, appState: appState) }
        }
        cachedCandidates = candidates
        cachedKey = key
        return candidates
    }
}
