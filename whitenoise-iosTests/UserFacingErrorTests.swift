import Foundation
import Testing
@testable import whitenoise_ios

struct UserFacingErrorTests {
    private struct RuntimeError: LocalizedError {
        let errorDescription: String?
    }

    @Test func duplicateIdentityUsesActionableCopyAndKeepsDiagnosticSeparate() {
        let error = RuntimeError(errorDescription: "MarmotKit.MarmotKitError.Runtime(details: \"account id is already in use: abc\")")

        let presentation = UserFacingError.present(title: "Import failed", error: error)

        #expect(presentation.title == "This identity is already on this device")
        #expect(presentation.message == "Use the existing profile instead of importing it again.")
        #expect(presentation.diagnostic.contains("account id is already in use"))
        #expect(!presentation.message.contains("MarmotKit"))
    }

    @Test func diagnosticsRedactSecretShapedInput() {
        let secret = "nsec1" + String(repeating: "q", count: 58)
        let error = RuntimeError(errorDescription: "runtime rejected \(secret)")

        let diagnostic = UserFacingError.sanitizedDiagnostic(for: error)

        #expect(diagnostic == "runtime rejected nsec1…")
    }

    @Test func ordinaryFailuresUseTheOperationTitleAndRetryCopy() {
        let error = RuntimeError(errorDescription: "network timed out")

        let toast = UserFacingError.toast(title: "Send failed", error: error)

        #expect(toast.title == "Send failed")
        #expect(toast.message == "Retry")
        #expect(toast.diagnostic == "network timed out")
    }
}
