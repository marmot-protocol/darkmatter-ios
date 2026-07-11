import Foundation
import Testing
@testable import whitenoise_ios

struct ConversationSearchPagingPolicyTests {

    @Test func loadsOlderPagesOnlyWhileHistoryRemains() {
        #expect(ConversationSearchPagingPolicy.shouldLoadOlderPage(hasMoreBefore: true, pagesLoaded: 0))
        #expect(!ConversationSearchPagingPolicy.shouldLoadOlderPage(hasMoreBefore: false, pagesLoaded: 0))
    }

    @Test func loadsOlderPagesOnlyWithinTheStepBudget() {
        let cap = ConversationSearchPagingPolicy.maxOlderPagesPerStep
        #expect(ConversationSearchPagingPolicy.shouldLoadOlderPage(hasMoreBefore: true, pagesLoaded: cap - 1))
        #expect(!ConversationSearchPagingPolicy.shouldLoadOlderPage(hasMoreBefore: true, pagesLoaded: cap))
        #expect(!ConversationSearchPagingPolicy.shouldLoadOlderPage(hasMoreBefore: true, pagesLoaded: cap + 1))
    }

    @Test func customCapIsHonored() {
        #expect(ConversationSearchPagingPolicy.shouldLoadOlderPage(hasMoreBefore: true, pagesLoaded: 0, cap: 1))
        #expect(!ConversationSearchPagingPolicy.shouldLoadOlderPage(hasMoreBefore: true, pagesLoaded: 1, cap: 1))
        #expect(!ConversationSearchPagingPolicy.shouldLoadOlderPage(hasMoreBefore: true, pagesLoaded: 0, cap: 0))
    }

    @Test func stepOutcomePrefersAFoundMatch() {
        #expect(
            ConversationSearchPagingPolicy.stepOutcome(foundOlderMatch: true, hasMoreBefore: true)
                == .foundOlderMatch
        )
        #expect(
            ConversationSearchPagingPolicy.stepOutcome(foundOlderMatch: true, hasMoreBefore: false)
                == .foundOlderMatch
        )
    }

    @Test func stepOutcomeIsCappedWhenHistoryRemainsUnsearched() {
        #expect(
            ConversationSearchPagingPolicy.stepOutcome(foundOlderMatch: false, hasMoreBefore: true)
                == .cappedWithMoreHistory
        )
    }

    @Test func stepOutcomeIsExhaustedAtTheStartOfHistory() {
        #expect(
            ConversationSearchPagingPolicy.stepOutcome(foundOlderMatch: false, hasMoreBefore: false)
                == .exhaustedHistory
        )
    }
}
