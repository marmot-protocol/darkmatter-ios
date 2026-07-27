import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct ReactionDetailsPresentationTests {
    @Test func groupsMultipleReactionsPerUserAndFiltersByEmoji() {
        let alice = String(repeating: "11", count: 32)
        let bob = String(repeating: "22", count: 32)
        let carol = String(repeating: "33", count: 32)
        let target = String(repeating: "aa", count: 32)
        let summary = TimelineReactionSummaryFfi(
            byEmoji: [
                TimelineReactionEmojiFfi(emoji: "👍", count: 2, senders: [alice, bob]),
                TimelineReactionEmojiFfi(emoji: "🔥", count: 1, senders: [alice]),
                TimelineReactionEmojiFfi(emoji: "😂", count: 1, senders: [carol]),
            ],
            userReactions: []
        )

        let details = ConversationViewModel.reactionDetails(
            for: target,
            summary: summary,
            optimisticRemovals: [],
            optimisticRecords: [:],
            deletedMessageIds: [],
            me: bob
        )

        #expect(details.groups.map(\.emoji) == ["👍", "🔥", "😂"])
        #expect(details.groups.map(\.count) == [2, 1, 1])
        #expect(details.groups.first?.mine == true)
        #expect(details.totalReactionCount == 4)

        let reactionsByUser = Dictionary(
            uniqueKeysWithValues: details.users(filteredBy: nil).map { ($0.sender, $0.emojis) }
        )
        #expect(reactionsByUser[alice] == ["👍", "🔥"])
        #expect(reactionsByUser[bob] == ["👍"])
        #expect(reactionsByUser[carol] == ["😂"])

        let thumbsUpUsers = details.users(filteredBy: "👍")
        #expect(thumbsUpUsers.map(\.sender) == [alice, bob])
        #expect(thumbsUpUsers.allSatisfy { $0.emojis == ["👍"] })
    }

    @Test func senderDetailsUseTheSameOptimisticOverlayAsBubbleTallies() {
        let me = String(repeating: "11", count: 32)
        let other = String(repeating: "22", count: 32)
        let target = String(repeating: "aa", count: 32)
        let summary = TimelineReactionSummaryFfi(
            byEmoji: [TimelineReactionEmojiFfi(emoji: "👍", count: 2, senders: [me, other])],
            userReactions: []
        )
        let optimistic = AppMessageRecordFfi(
            messageIdHex: "optimistic-reaction",
            direction: "sent",
            groupIdHex: String(repeating: "bb", count: 32),
            sender: me,
            plaintext: "🔥",
            kind: MessageSemantics.kindReaction,
            tags: [MessageTagFfi(values: [MessageSemantics.eventRefTag, target])],
            recordedAt: 10,
            receivedAt: 10
        )

        let details = ConversationViewModel.reactionDetails(
            for: target,
            summary: summary,
            optimisticRemovals: [ReactionRemoval(
                targetMessageIdHex: target,
                emoji: "👍",
                sender: me
            )],
            optimisticRecords: ["optimistic-reaction": optimistic],
            deletedMessageIds: [],
            me: me
        )

        #expect(details.tallies == [
            ConversationViewModel.ReactionTally(emoji: "👍", count: 1, mine: false),
            ConversationViewModel.ReactionTally(emoji: "🔥", count: 1, mine: true),
        ])
        #expect(details.users(filteredBy: "👍").map(\.sender) == [other])
        #expect(details.users(filteredBy: "🔥").map(\.sender) == [me])
    }

    @MainActor
    @Test func messageInfoOmitsMissingTimestampsAndFormatsKnownOnes() {
        #expect(MessageInfoPresentation.timestampLabel(0, locale: Locale(identifier: "en_US")) == nil)
        let label = MessageInfoPresentation.timestampLabel(1, locale: Locale(identifier: "en_US"))
        #expect(label?.isEmpty == false)
    }

    @MainActor
    @Test func messageExpirationLabelIsRelativeNearbyAndAbsoluteBeyondOneDay() throws {
        let locale = Locale(identifier: "en_US")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let near = UInt64(now.addingTimeInterval(5 * 60).timeIntervalSince1970)
        let far = UInt64(now.addingTimeInterval(2 * 24 * 60 * 60).timeIntervalSince1970)

        let nearLabel = try #require(MessageExpirationPresentation.detailLabel(
            expiresAt: near,
            now: now,
            locale: locale
        ))
        let farLabel = try #require(MessageExpirationPresentation.detailLabel(
            expiresAt: far,
            now: now,
            locale: locale
        ))

        #expect(nearLabel.lowercased().contains("minute"))
        #expect(farLabel == MessageInfoPresentation.timestampLabel(far, locale: locale))
        #expect(MessageExpirationPresentation.detailLabel(
            expiresAt: UInt64(now.timeIntervalSince1970),
            now: now,
            locale: locale
        ) == "Expired")
    }
}
