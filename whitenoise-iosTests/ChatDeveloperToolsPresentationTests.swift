import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct ChatDeveloperToolsPresentationTests {
    @Test func lifecyclePrioritizesTerminalAndPendingStates() {
        #expect(ChatDeveloperToolsPresentation.lifecycleLabel(
            membership: .member,
            leaveRequestPending: false,
            isDisbanding: false,
            isDisbanded: false
        ) == L10n.string("Active"))
        #expect(ChatDeveloperToolsPresentation.lifecycleLabel(
            membership: .member,
            leaveRequestPending: true,
            isDisbanding: false,
            isDisbanded: false
        ) == L10n.string("Leaving"))
        #expect(ChatDeveloperToolsPresentation.lifecycleLabel(
            membership: .member,
            leaveRequestPending: true,
            isDisbanding: true,
            isDisbanded: false
        ) == L10n.string("Ending"))
        #expect(ChatDeveloperToolsPresentation.lifecycleLabel(
            membership: .member,
            leaveRequestPending: true,
            isDisbanding: true,
            isDisbanded: true
        ) == L10n.string("Ended"))
    }

    @Test func lifecycleReflectsInactiveMembership() {
        #expect(ChatDeveloperToolsPresentation.lifecycleLabel(
            membership: .left,
            leaveRequestPending: false,
            isDisbanding: false,
            isDisbanded: false
        ) == L10n.string("Left"))
        #expect(ChatDeveloperToolsPresentation.lifecycleLabel(
            membership: .removed,
            leaveRequestPending: false,
            isDisbanding: false,
            isDisbanded: false
        ) == L10n.string("Removed"))
    }
}
