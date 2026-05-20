import Testing
import Foundation
@testable import darkmatter_ios
@testable import MarmotKit

/// Smoke coverage for the iOS-side glue layer.
///
/// Full functional tests require running against a Nostr relay (handled by
/// `marmot-uniffi`'s Rust integration tests). These tests just exercise the
/// boundary between MarmotKit and the iOS code, plus pure-Swift helpers.
struct AppStateBootstrapTests {

    @Test func freshAppStateStartsBootstrapping() async throws {
        let appState = AppState()
        #expect(appState.phase == .bootstrapping)
        #expect(appState.accounts.isEmpty)
        #expect(appState.activeToast == nil)
    }

    @Test func bootstrapWithoutAccountsTransitionsToOnboarding() async throws {
        // Use a fresh AppState backed by a tempdir-based MarmotClient so
        // we don't collide with the user's real Application Support data.
        let appState = AppState(client: MarmotClient.testClient())
        await appState.bootstrap()
        #expect(appState.phase == .onboarding)
        #expect(appState.accounts.isEmpty)
    }

    @Test func presentingAToastUpdatesActiveToast() async throws {
        let appState = AppState()
        await MainActor.run {
            appState.present(.success("Hello"))
        }
        #expect(appState.activeToast?.title == "Hello")
        #expect(appState.activeToast?.style == .success)

        await MainActor.run { appState.dismissToast() }
        #expect(appState.activeToast == nil)
    }
}

struct IdentityFormatterTests {

    @Test func shortTruncatesLongStrings() {
        let long = "npub1abcdefghijklmnopqrstuvwxyz0123456789"
        let s = IdentityFormatter.short(long)
        #expect(s.contains("…"))
        #expect(s.count < long.count)
    }

    @Test func shortPassesShortStringsUnchanged() {
        let short = "abc"
        #expect(IdentityFormatter.short(short) == short)
    }

    @Test func displayNameFallsBackToShortIdWhenLabelEmpty() {
        let id = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"
        let result = IdentityFormatter.displayName(label: "", accountIdHex: id)
        #expect(result.contains("…"))
    }
}

// MARK: - Test scaffolding

extension MarmotClient {
    /// Builds a MarmotClient pointed at a unique temp directory so unit tests
    /// stay hermetic. Falls back to the production root only if the temp dir
    /// can't be created (which would itself be a test environment problem).
    static func testClient() -> MarmotClient {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarmotTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return MarmotClient(rootPath: tmp.path, relayUrls: ["wss://relay.invalid.test"])
    }
}
