import Foundation

/// Separates the short, actionable error copy we show in the UI from the
/// diagnostic supplied by the runtime or an underlying framework.
struct UserFacingError: Equatable {
    let title: String
    let message: String
    let diagnostic: String

    static func toast(title: String, error: Error, fallbackMessage: String? = nil) -> Toast {
        let presentation = present(title: title, error: error, fallbackMessage: fallbackMessage)
        return Toast.error(
            presentation.title,
            message: presentation.message,
            diagnostic: presentation.diagnostic
        )
    }

    static func present(title: String, error: Error, fallbackMessage: String? = nil) -> UserFacingError {
        let diagnostic = sanitizedDiagnostic(for: error)
        if diagnostic.localizedCaseInsensitiveContains("account id is already in use") {
            return UserFacingError(
                title: L10n.string("This identity is already on this device"),
                message: L10n.string("Use the existing profile instead of importing it again."),
                diagnostic: diagnostic
            )
        }

        return UserFacingError(
            title: title,
            message: fallbackMessage ?? L10n.string("Retry"),
            diagnostic: diagnostic
        )
    }

    /// Runtime errors may include an nsec if input validation failed. Never
    /// make a secret copyable from a diagnostic surface.
    static func sanitizedDiagnostic(for error: Error) -> String {
        let raw = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        return raw
            .replacing(/nsec1[a-z0-9]+/.ignoresCase(), with: "nsec1…")
            .replacing(/[0-9a-fA-F]{64,}/, with: "…")
            .prefix(4_000)
            .description
    }
}
