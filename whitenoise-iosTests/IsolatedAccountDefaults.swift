import Foundation

/// A preference domain scoped to one test, so parallel suites cannot observe or
/// clobber each other's persisted active-account selection.
///
/// `AccountStore` persists to `UserDefaults.standard` in the app. Swift Testing
/// runs suites concurrently in a single process, so any test that asserts on the
/// persisted selection races every other suite that creates an identity or
/// assigns `activeAccountRef`.
enum IsolatedAccountDefaults {
    static func make(
        _ label: String = #function,
        file: String = #fileID
    ) -> UserDefaults {
        let suiteName = [
            "dev.ipf.whitenoise.ios.tests.account",
            String(ProcessInfo.processInfo.processIdentifier),
            sanitized(file),
            sanitized(label),
            UUID().uuidString
        ].joined(separator: ".")

        guard let defaults = UserDefaults(suiteName: suiteName) else { return .standard }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private static func sanitized(_ value: String) -> String {
        let allowed = value.map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        return String(allowed)
    }
}
