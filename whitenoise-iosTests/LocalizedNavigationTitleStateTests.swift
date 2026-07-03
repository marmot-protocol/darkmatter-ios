import Foundation
import Testing
@testable import whitenoise_ios

struct LocalizedNavigationTitleStateTests {
    @Test func titleSnapshotsProviderOnInit() {
        let state = LocalizedNavigationTitleState(resolve: { "Settings" })

        #expect(state.title == "Settings")
    }

    // The bug the modifier fixes: the plain-String title is a snapshot and stays
    // stale after the language changes until something re-resolves it.
    @Test func titleStaysStaleUntilRefreshed() {
        var current = "Settings"
        let state = LocalizedNavigationTitleState(resolve: { current })

        current = "Configuracion"

        #expect(state.title == "Settings")
    }

    @Test func refreshRecomputesTitleFromProvider() {
        var current = "Settings"
        var state = LocalizedNavigationTitleState(resolve: { current })

        current = "Configuracion"
        state.refresh()

        #expect(state.title == "Configuracion")
    }

    // The production convenience resolves through L10n, so it follows the in-app
    // language selection rather than the device locale.
    @Test func titleResolvesThroughInAppLanguage() {
        withAppLanguage(.english) {
            let state = LocalizedNavigationTitleState(resolve: { L10n.string("Settings") })

            #expect(state.title == "Settings")
        }
    }
}
