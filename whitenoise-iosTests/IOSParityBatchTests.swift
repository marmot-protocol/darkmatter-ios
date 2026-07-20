import Foundation
import Testing
@testable import MarmotKit
@testable import whitenoise_ios

@MainActor
struct IOSParityBatchTests {
    @Test func namedGroupsCanBeCreatedWithoutInvitees() {
        #expect(AddMembersPresentation.canCreate(
            stagedCount: 0,
            hasUsableName: true,
            isCreating: false,
            hasActiveAccount: true
        ))
        #expect(!AddMembersPresentation.canCreate(
            stagedCount: 0,
            hasUsableName: false,
            isCreating: false,
            hasActiveAccount: true
        ))
        #expect(AddMembersPresentation.canCreate(
            stagedCount: 1,
            hasUsableName: false,
            isCreating: false,
            hasActiveAccount: true
        ))
        #expect(!AddMembersPresentation.canInvite(stagedCount: 0, isInviting: false))
    }

    @Test func emptyGroupInviteRequiresConfirmedSoleMemberAdmin() {
        #expect(EmptyGroupConversationPresentation.canInvite(
            isSelfMember: true,
            isSelfAdmin: true,
            membersLoaded: true,
            memberCount: 1,
            onlyMemberIsSelf: true
        ))
        #expect(!EmptyGroupConversationPresentation.canInvite(
            isSelfMember: true,
            isSelfAdmin: true,
            membersLoaded: false,
            memberCount: 0,
            onlyMemberIsSelf: false
        ))
        #expect(!EmptyGroupConversationPresentation.canInvite(
            isSelfMember: true,
            isSelfAdmin: false,
            membersLoaded: true,
            memberCount: 1,
            onlyMemberIsSelf: true
        ))
    }

    @Test func quickReactionChoicesAreStableUniqueAndFilledToSix() {
        #expect(QuickReactionChoices.normalize(["🔥", "🔥", "\u{202E}", "👍"]) == [
            "🔥", "👍", "❤️", "👎", "😂", "😮",
        ])
        #expect(QuickReactionChoices.normalize(["❤", "❤️"]).filter { $0 == "❤" || $0 == "❤️" }.count == 1)
    }

    @Test func customizedQuickReactionsPersistAndOverrideRecents() throws {
        let suiteName = "IOSParityBatchTests.quickReactions.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(QuickReactionChoices.resolved(
            customized: nil,
            recent: ["🔥"]
        ) == ["🔥", "❤️", "👍", "👎", "😂", "😮"])

        let saved = QuickReactionPreferences.save(
            ["🚀", "✅", "🎉", "👀", "🙏", "💯"],
            to: defaults
        )
        let reloaded = QuickReactionPreferences.load(from: defaults)

        #expect(reloaded == saved)
        #expect(QuickReactionChoices.resolved(
            customized: reloaded,
            recent: ["🔥", "😢"]
        ) == saved)

        let reset = QuickReactionPreferences.save(AppState.defaultReactions, to: defaults)
        #expect(QuickReactionPreferences.load(from: defaults) == AppState.defaultReactions)
        #expect(QuickReactionChoices.resolved(
            customized: reset,
            recent: ["🔥"]
        ) == AppState.defaultReactions)
    }

    @Test func activeRetentionReplacesMemberSubtitleButConnectingWins() {
        #expect(ConversationHeaderSecondary.resolve(
            isRuntimeWarmingUp: false,
            subtitle: "4 members",
            retentionSeconds: 300
        ) == .retention(300))
        #expect(ConversationHeaderSecondary.resolve(
            isRuntimeWarmingUp: true,
            subtitle: "4 members",
            retentionSeconds: 300
        ) == .connecting)
    }

    @Test func backgroundRefreshIdentifierTracksBundleFlavor() {
        #expect(MessageRetentionBackgroundRefreshPolicy.taskIdentifier(
            bundleIdentifier: "dev.ipf.whitenoise.ios.staging"
        ) == "dev.ipf.whitenoise.ios.staging.retention-sweep")
        #expect(MessageRetentionBackgroundRefreshPolicy.earliestDelay >= 15 * 60)
    }

    @Test func mediaLocatorStaticValidationAllowsOnlyPublicHttpsBlossom() {
        #expect(EncryptedMediaLocatorValidation.isStaticallySafe([
            locator("https://media.example/blob"),
        ]))
        #expect(!EncryptedMediaLocatorValidation.isStaticallySafe([
            locator("http://media.example/blob"),
        ]))
        #expect(!EncryptedMediaLocatorValidation.isStaticallySafe([
            locator("https://user:password@media.example/blob"),
        ]))
        #expect(!EncryptedMediaLocatorValidation.isStaticallySafe([
            locator("https://media.example:8443/blob"),
        ]))
        #expect(!EncryptedMediaLocatorValidation.isStaticallySafe([
            locator("not a url"),
        ]))
        #expect(!EncryptedMediaLocatorValidation.isStaticallySafe([
            locator("https://127.0.0.1/blob"),
        ]))
        #expect(!EncryptedMediaLocatorValidation.isStaticallySafe([
            locator("https://service.localhost/blob"),
        ]))
        #expect(!EncryptedMediaLocatorValidation.isStaticallySafe([
            locator("https://media.example/blob"),
            locator("https://10.0.0.5/private"),
        ]))
        #expect(EncryptedMediaLocatorValidation.isStaticallySafe([
            MediaLocatorFfi(kind: "ipfs-v1", value: "https://10.0.0.5/private"),
            locator("https://media.example/blob"),
        ]))
        #expect(!EncryptedMediaLocatorValidation.isStaticallySafe([
            MediaLocatorFfi(kind: "ipfs-v1", value: "https://media.example/blob"),
        ]))
    }

    @Test func mediaLocatorResolutionFailsClosedOnPrivateOrMissingDns() {
        let locators = [locator("https://media.example/blob")]
        #expect(EncryptedMediaLocatorValidation.resolvesOnlyToPublicAddresses(locators) { _ in
            ["93.184.216.34"]
        })
        #expect(!EncryptedMediaLocatorValidation.resolvesOnlyToPublicAddresses(locators) { _ in
            ["10.0.0.5"]
        })
        #expect(!EncryptedMediaLocatorValidation.resolvesOnlyToPublicAddresses(locators) { _ in
            []
        })
    }

    @Test func optimisticImetaParserRejectsUnsafeLocator() {
        let values = [
            MessageSemantics.imetaTag,
            "v \(MessageSemantics.encryptedMediaVersion)",
            "locator blossom-v1 https://192.168.1.1/blob",
            "ciphertext_sha256 \(String(repeating: "a", count: 64))",
            "plaintext_sha256 \(String(repeating: "b", count: 64))",
            "nonce \(String(repeating: "c", count: 24))",
            "m image/jpeg",
            "filename photo.jpg",
        ]
        #expect(MessageSemantics.mediaAttachments(from: [MessageTagFfi(values: values)]) == nil)
    }

    @Test func optimisticImetaParserRejectsOversizedFieldAndLocatorCollections() {
        let requiredFields = [
            "v \(MessageSemantics.encryptedMediaVersion)",
            "ciphertext_sha256 \(String(repeating: "a", count: 64))",
            "plaintext_sha256 \(String(repeating: "b", count: 64))",
            "nonce \(String(repeating: "c", count: 24))",
            "m image/jpeg",
            "filename photo.jpg",
        ]
        let tooManyFields = [MessageSemantics.imetaTag]
            + requiredFields
            + (0...(MessageSemantics.maxImetaFieldsPerTag - requiredFields.count)).map {
                "blurhash ignored-\($0)"
            }
        let tooManyLocators = [MessageSemantics.imetaTag]
            + requiredFields
            + (0...MessageSemantics.maxImetaLocatorsPerTag).map {
                "locator blossom-v1 https://media.example/blob-\($0)"
            }

        #expect(MessageSemantics.mediaAttachments(
            from: [MessageTagFfi(values: tooManyFields)]
        ) == nil)
        #expect(MessageSemantics.mediaAttachments(
            from: [MessageTagFfi(values: tooManyLocators)]
        ) == nil)
    }

    private func locator(_ value: String) -> MediaLocatorFfi {
        MediaLocatorFfi(kind: EncryptedMediaLocatorValidation.blossomKind, value: value)
    }
}
