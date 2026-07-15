import Testing
@testable import whitenoise_ios
@testable import MarmotKit
@MainActor
struct GroupNameValidationTests {

    @Test func rejectsEmptyOrWhitespaceDraft() {
        #expect(GroupDetailsView.validatedGroupName("") == nil)
        #expect(GroupDetailsView.validatedGroupName("   \n\t ") == nil)
    }

    @Test func trimsAndAcceptsNonEmptyName() {
        #expect(GroupDetailsView.validatedGroupName("  Team Rocket  ") == "Team Rocket")
    }

    @Test func renameDraftSanitizesAndCapsGroupName() throws {
        let hostile = "\u{202E}Team\nRocket" + String(repeating: "x", count: 150)
        let sanitized = try #require(GroupDetailsView.validatedGroupName(hostile))

        #expect(sanitized.hasPrefix("Team Rocket"))
        #expect(!sanitized.contains("\u{202E}"))
        #expect(!sanitized.contains("\n"))
        #expect(sanitized.count == ContentSanitizer.maxGroupNameLength)
    }

    @Test func newGroupNameUsesSanitizedEmptyStringSentinel() {
        #expect(NewGroupPresentation.normalizedName("") == "")
        #expect(NewGroupPresentation.normalizedName(" \n\t ") == "")
        #expect(NewGroupPresentation.normalizedName(" \u{202E}Research\nLab ") == "Research Lab")
    }

    @Test func newGroupDescriptionSanitizesCapsAndDropsBlankValues() {
        #expect(NewGroupPresentation.normalizedDescription("") == nil)
        #expect(NewGroupPresentation.normalizedDescription(" \n\t ") == nil)
        let description = NewGroupPresentation.normalizedDescription("  Mission\u{202E}\n\n\nnotes  ")
        #expect(description == "Mission\n\nnotes")

        let oversized = NewGroupPresentation.normalizedDescription(String(repeating: "x", count: 500))
        #expect(oversized?.count == ContentSanitizer.maxGroupDescriptionLength)
    }

    @Test func groupDescriptionUpdateUsesAnEmptyStringToExplicitlyClear() {
        #expect(GroupDetailsView.normalizedGroupDescriptionForUpdate("") == "")
        #expect(GroupDetailsView.normalizedGroupDescriptionForUpdate(" \n\t ") == "")

        let normalized = GroupDetailsView.normalizedGroupDescriptionForUpdate(
            "  Mission\u{202E}\n\n\nnotes  "
        )
        #expect(normalized == "Mission\n\nnotes")

        let oversized = GroupDetailsView.normalizedGroupDescriptionForUpdate(
            String(repeating: "x", count: 500)
        )
        #expect(oversized.count == ContentSanitizer.maxGroupDescriptionLength)
    }
}
