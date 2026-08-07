import Foundation
import MarmotKit
import Testing
@testable import whitenoise_ios

struct UserFacingErrorTests {
    private struct RuntimeError: LocalizedError {
        let errorDescription: String?
    }

    @Test func typedDuplicateIdentityUsesActionableCopy() {
        let error = MarmotKitError.DuplicateIdentity(account: "existing-account")

        let presentation = UserFacingError.present(title: "Import failed", error: error)

        #expect(presentation.title == "Import failed")
        #expect(presentation.message == "Identity already signed in on this device")
        #expect(!presentation.message.contains("MarmotKit"))
    }

    @Test func legacyDuplicateIdentityDiagnosticUsesActionableCopy() {
        let error = RuntimeError(errorDescription: "MarmotKit.MarmotKitError.Runtime(details: \"account id is already in use: abc\")")

        let presentation = UserFacingError.present(title: "Import failed", error: error)

        #expect(presentation.message == "Identity already signed in on this device")
        #expect(presentation.diagnostic.contains("account id is already in use"))
    }

    @Test func diagnosticsRedactSecretShapedInput() {
        let secret = "nsec1" + String(repeating: "q", count: 58)
        let error = RuntimeError(errorDescription: "runtime rejected \(secret)")

        let diagnostic = UserFacingError.sanitizedDiagnostic(for: error)

        #expect(diagnostic == "runtime rejected nsec1…")
    }

    @Test func accountSetupErrorsUseActionableCopy() {
        let recovery = UserFacingError.present(
            title: "Import failed",
            error: MarmotKitError.AccountSetupRecoveryRequired
        )
        let retry = UserFacingError.present(
            title: "Import failed",
            error: MarmotKitError.AccountSetupRetryRequired
        )

        #expect(recovery.message == "Incomplete identity setup needs approval to recover.")
        #expect(retry.message == "Identity setup can be resumed. Try importing again.")
    }

    @Test func ordinaryFailuresUseTheOperationTitleAndRetryCopy() {
        let error = RuntimeError(errorDescription: "network timed out")

        let toast = UserFacingError.toast(title: "Send failed", error: error)

        #expect(toast.title == "Send failed")
        #expect(toast.message == "Retry")
        #expect(toast.diagnostic == "network timed out")
    }

    @Test func fullGroupSendQueueExplainsWhenToResend() {
        let presentation = UserFacingError.present(
            title: "Send failed",
            error: MarmotKitError.GroupSendQueueFull(groupIdHex: "group-id")
        )

        #expect(presentation.message == "This chat is still catching up. Wait for it to finish, then resend your message.")
        #expect(!presentation.message.contains("group-id"))
    }
}
