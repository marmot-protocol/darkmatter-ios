import Foundation
import MarmotKit

/// Screen-lifetime live search over the active account's Marmot web of trust.
///
/// Results and their profiles deliberately remain ephemeral. MDK does not
/// promote discovered strangers into the local directory, and the UI mirrors
/// that boundary until the user explicitly starts a conversation or invite.
@MainActor
@Observable
final class RecipientUserSearch {
    private(set) var results: [UserDirectorySearchResultFfi] = []
    private(set) var followedAccountIds: Set<String> = []
    private(set) var isSearching = false
    private(set) var isIncomplete = false
    private(set) var didFail = false

    private var task: Task<Void, Never>?
    private var requestID: UUID?
    private var activeQuery = ""

    private static let radiusStart: UInt8 = 1
    private static let radiusEnd: UInt8 = 2

    var candidates: [RecipientCandidate] {
        results.map {
            RecipientCandidate(
                accountIdHex: $0.accountIdHex.lowercased(),
                npub: $0.npub,
                lastActivityAt: 0,
                directChatGroupIdHex: nil,
                sharedChatCount: 0,
                searchProfile: $0.profile,
                searchRadius: $0.radius,
                isFollowedBySearcher: followedAccountIds.contains($0.accountIdHex.lowercased())
            )
        }
    }

    func update(
        query rawQuery: String,
        isIdentifierQuery: Bool,
        using appState: AppState
    ) {
        let query = Self.normalizedQuery(rawQuery)
        task?.cancel()
        task = nil
        requestID = nil
        activeQuery = query
        results = []
        followedAccountIds = []
        isSearching = false
        isIncomplete = false
        didFail = false

        guard Self.shouldSearch(query: query, isIdentifierQuery: isIdentifierQuery),
              let accountIdHex = appState.activeAccount?.accountIdHex,
              let accountRef = appState.activeAccountRef
        else { return }

        let id = UUID()
        requestID = id
        isSearching = true
        task = Task { [weak self, weak appState] in
            do {
                try await Task.sleep(for: .milliseconds(300))
                try Task.checkCancellation()
                guard let self, let appState else { return }
                let client = try appState.currentMarmotClient()
                async let follows = client.accountFollows(accountRef: accountRef)
                let subscription = try await client.marmot.searchUsers(
                    accountIdHex: accountIdHex,
                    query: query,
                    radiusStart: Self.radiusStart,
                    radiusEnd: Self.radiusEnd
                )
                let followedAccountIds = (try? await follows) ?? []
                guard self.requestIsCurrent(id: id, query: query), !Task.isCancelled else {
                    return
                }
                self.followedAccountIds = followedAccountIds
                await self.consume(
                    subscription,
                    requestID: id,
                    query: query
                )
            } catch is CancellationError {
                return
            } catch {
                guard let self else { return }
                self.finishFailedRequest(id: id, query: query)
            }
        }
    }

    func retry(using appState: AppState) {
        update(query: activeQuery, isIdentifierQuery: false, using: appState)
    }

    func cancel() {
        task?.cancel()
        task = nil
        requestID = nil
        results = []
        followedAccountIds = []
        isSearching = false
        isIncomplete = false
        didFail = false
    }

    private func consume(
        _ subscription: UserSearchSubscription,
        requestID id: UUID,
        query: String
    ) async {
        var aggregate: [UserDirectorySearchResultFfi] = []
        while !Task.isCancelled, let update = await subscription.nextUpdate() {
            guard requestIsCurrent(id: id, query: query), !Task.isCancelled else { return }
            aggregate.append(contentsOf: update.newResults)
            results = Self.sortedUniqueResults(
                aggregate,
                followedAccountIds: followedAccountIds
            )

            switch update.trigger {
            case .radiusTimeout, .radiusTruncated:
                isIncomplete = true
            case .error:
                didFail = true
            case .searchCompleted:
                finishRequest(id: id, query: query)
                return
            case .radiusStarted, .resultsFound, .discoveryResultsFound, .radiusCompleted:
                break
            }
        }
        finishRequest(id: id, query: query)
    }

    private func finishFailedRequest(id: UUID, query: String) {
        guard requestIsCurrent(id: id, query: query) else { return }
        didFail = true
        finishRequest(id: id, query: query)
    }

    private func finishRequest(id: UUID, query: String) {
        guard requestIsCurrent(id: id, query: query) else { return }
        isSearching = false
        task = nil
        requestID = nil
    }

    private func requestIsCurrent(id: UUID, query: String) -> Bool {
        requestID == id && activeQuery == query
    }

    func setFollowStatus(accountIdHex: String, isFollowing: Bool) {
        let accountIdHex = accountIdHex.lowercased()
        if isFollowing {
            followedAccountIds.insert(accountIdHex)
        } else {
            followedAccountIds.remove(accountIdHex)
        }
        results = Self.sortedUniqueResults(
            results,
            followedAccountIds: followedAccountIds
        )
    }

    nonisolated static func shouldSearch(query: String, isIdentifierQuery: Bool) -> Bool {
        !isIdentifierQuery && !normalizedQuery(query).isEmpty
    }

    nonisolated static func sortedUniqueResults(
        _ results: [UserDirectorySearchResultFfi],
        followedAccountIds: Set<String> = []
    ) -> [UserDirectorySearchResultFfi] {
        let sorted = results.sorted {
            let lhsFollowed = followedAccountIds.contains($0.accountIdHex.lowercased())
            let rhsFollowed = followedAccountIds.contains($1.accountIdHex.lowercased())
            if lhsFollowed != rhsFollowed {
                return lhsFollowed
            }
            if $0.radius != $1.radius {
                return $0.radius < $1.radius
            }
            let lhsProviderRank = $0.providerRank ?? -.infinity
            let rhsProviderRank = $1.providerRank ?? -.infinity
            if lhsProviderRank != rhsProviderRank {
                return lhsProviderRank > rhsProviderRank
            }
            let lhsQuality = matchQualityRank($0.matchQuality)
            let rhsQuality = matchQualityRank($1.matchQuality)
            if lhsQuality != rhsQuality {
                return lhsQuality < rhsQuality
            }
            let lhsField = matchedFieldRank($0.matchedField)
            let rhsField = matchedFieldRank($1.matchedField)
            if lhsField != rhsField {
                return lhsField < rhsField
            }
            return $0.accountIdHex < $1.accountIdHex
        }
        var seen: Set<String> = []
        return sorted.filter {
            seen.insert($0.accountIdHex.lowercased()).inserted
        }
    }

    private nonisolated static func normalizedQuery(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func matchQualityRank(_ quality: MatchQualityFfi) -> Int {
        switch quality {
        case .exact: 0
        case .prefix: 1
        case .contains: 2
        }
    }

    private nonisolated static func matchedFieldRank(_ field: MatchedFieldFfi) -> Int {
        switch field {
        case .name: 0
        case .nip05: 1
        case .displayName: 2
        case .about: 3
        case .npub: 4
        case .pubkey: 5
        }
    }
}
