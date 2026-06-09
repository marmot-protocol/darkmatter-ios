import Testing
import Foundation
@testable import darkmatter_ios

/// Source-level regressions for two fixes whose runtime surfaces (a SwiftUI View
/// method's ordering, and an async cancellation path inside a real-IO loop)
/// can't be exercised directly in a unit test.
struct SendDispatchAndCancellationTests {

    /// #49 — send() must confirm it has a view model before clearing the draft,
    /// otherwise a nil view model at dispatch time silently discards the message.
    @Test func sendGuardsViewModelBeforeClearingDraft() throws {
        let source = try sourceString("darkmatter-ios/Conversation/ConversationView.swift")
        let pattern = #"private func send\(\) \{[\s\S]*?guard let viewModel else \{ return \}[\s\S]*?draft = """#
        #expect(source.range(of: pattern, options: .regularExpression) != nil)
    }

    /// #76 — push registration must treat CancellationError as a non-failure and
    /// not surface it as "Push registration failed".
    @Test func pushRegistrationIgnoresCancellation() throws {
        let source = try sourceString("darkmatter-ios/Core/AppState.swift")
        // The CancellationError branch must exist and must NOT surface the error
        // toast — assert the failure string is absent from that catch block, yet
        // present elsewhere (the generic catch).
        let cancellationPattern = #"catch is CancellationError\s*\{[\s\S]*?\}"#
        guard let range = source.range(of: cancellationPattern, options: .regularExpression) else {
            Issue.record("Expected an explicit CancellationError catch block")
            return
        }
        let cancellationBody = String(source[range])
        #expect(!cancellationBody.contains("Push registration failed"))
        #expect(source.contains("Push registration failed"))
    }

    private func sourceString(_ relativePath: String) throws -> String {
        let url = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
