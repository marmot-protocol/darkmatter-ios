import Foundation
import MarmotKit

/// Owns the per-account unread totals shown as badges on the account switcher.
/// A dumb mirror of Marmot's materialized chat-list aggregate, patched from
/// live active-list updates. Kept pure: index mutations take the current
/// `accounts` as a parameter, so the store needs no `AppState` back-reference —
/// AppState performs the Marmot fetch (its domain) and feeds the result here.
@MainActor
@Observable
final class AccountUnreadStore {
    /// Cached per-account unread totals keyed by account id hex.
    private(set) var byAccountId: [String: AccountUnreadFfi] = [:]
    private var supplementalUnreadConversationCountsByAccountId: [String: UInt64] = [:]
    private var incrementalRevision: UInt64 = 0
    private var incrementalRevisionByAccountId: [String: UInt64] = [:]

    func summary(forAccountIdHex accountIdHex: String) -> AccountUnreadFfi? {
        byAccountId[accountIdHex]
    }

    func badgeCount(forAccountIdHex accountIdHex: String) -> UInt64? {
        guard let summary = byAccountId[accountIdHex] else { return nil }
        let count = ApplicationBadgeCountProjection.contribution(
            for: summary,
            supplementalUnreadConversationCount:
                supplementalUnreadConversationCountsByAccountId[accountIdHex, default: 0]
        )
        return count > 0 ? count : nil
    }

    func applicationBadgeCount() -> Int {
        ApplicationBadgeCountProjection.count(
            for: byAccountId.values,
            supplementalUnreadConversationCounts:
                supplementalUnreadConversationCountsByAccountId
        )
    }

    /// Replace the whole index from a fresh Marmot aggregate. Empty accounts
    /// clears it (nothing to attribute unread to).
    func incrementalRevisionSnapshot() -> [String: UInt64] {
        incrementalRevisionByAccountId
    }

    func refreshed(
        from summaries: [AccountUnreadFfi],
        accounts: [AccountSummaryFfi],
        supplementalUnreadConversationCounts: [String: UInt64] = [:],
        preservingUpdatesAfter baseline: [String: UInt64] = [:]
    ) {
        guard !accounts.isEmpty else {
            byAccountId = [:]
            supplementalUnreadConversationCountsByAccountId = [:]
            incrementalRevisionByAccountId = [:]
            return
        }
        var refreshed = AccountUnreadSummaryProjection.byAccountId(summaries, accounts: accounts)
        let knownAccountIds = Set(accounts.map(\.accountIdHex))
        var refreshedSupplementalCounts = supplementalUnreadConversationCounts.filter {
            knownAccountIds.contains($0.key)
        }
        for account in accounts {
            let accountIdHex = account.accountIdHex
            let hasNewerLiveUpdate = incrementalRevisionByAccountId[accountIdHex, default: 0]
                > baseline[accountIdHex, default: 0]
            if hasNewerLiveUpdate, let live = byAccountId[accountIdHex] {
                refreshed[accountIdHex] = live
            }
            if (hasNewerLiveUpdate || refreshedSupplementalCounts[accountIdHex] == nil),
               let liveSupplementalCount =
                supplementalUnreadConversationCountsByAccountId[accountIdHex] {
                refreshedSupplementalCounts[accountIdHex] = liveSupplementalCount
            }
        }
        byAccountId = refreshed
        supplementalUnreadConversationCountsByAccountId = refreshedSupplementalCounts
        incrementalRevisionByAccountId = incrementalRevisionByAccountId.filter {
            knownAccountIds.contains($0.key)
        }
    }

    /// Patch one account's total from a live chat-list update; ignores ids that
    /// aren't currently known accounts.
    func update(accountIdHex: String, chatListRows: [ChatListRowFfi], accounts: [AccountSummaryFfi]) {
        guard accounts.contains(where: { $0.accountIdHex == accountIdHex }) else { return }
        incrementalRevision &+= 1
        incrementalRevisionByAccountId[accountIdHex] = incrementalRevision
        byAccountId[accountIdHex] = AccountUnreadSummaryProjection.summary(
            accountIdHex: accountIdHex,
            rows: chatListRows
        )
        supplementalUnreadConversationCountsByAccountId[accountIdHex] =
            ApplicationBadgeCountProjection
            .supplementalUnreadConversationCount(in: chatListRows)
    }

    /// Drop entries for accounts that no longer exist (used as the fallback when
    /// a refresh fetch fails, so stale signed-out totals don't linger).
    func pruneToCurrentAccounts(_ accounts: [AccountSummaryFfi]) {
        let knownAccountIds = Set(accounts.map(\.accountIdHex))
        byAccountId = byAccountId.filter { knownAccountIds.contains($0.key) }
        supplementalUnreadConversationCountsByAccountId =
            supplementalUnreadConversationCountsByAccountId.filter {
                knownAccountIds.contains($0.key)
            }
        incrementalRevisionByAccountId = incrementalRevisionByAccountId.filter {
            knownAccountIds.contains($0.key)
        }
    }
}
