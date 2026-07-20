import Foundation

/// Normalizes the six user-configurable quick reactions. Variation selectors
/// do not make otherwise-identical glyphs distinct, matching Android.
nonisolated enum QuickReactionChoices {
    static let limit = 6

    static func normalize(
        _ choices: [String],
        defaults: [String] = AppState.defaultReactions
    ) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in choices + defaults {
            let emoji = ContentSanitizer.reactionEmoji(raw)
            guard !emoji.isEmpty else { continue }
            let identity = emoji.unicodeScalars
                .filter { $0.value != 0xFE0E && $0.value != 0xFE0F }
                .map(String.init)
                .joined()
            guard seen.insert(identity).inserted else { continue }
            result.append(emoji)
            if result.count == limit { break }
        }
        return result
    }

    static func recentChoices(
        recent: [String],
        defaults: [String] = AppState.defaultReactions
    ) -> [String] {
        normalize(recent, defaults: defaults)
    }

    static func resolved(
        customized: [String]?,
        recent: [String],
        defaults: [String] = AppState.defaultReactions
    ) -> [String] {
        customized.map { normalize($0, defaults: defaults) }
            ?? recentChoices(recent: recent, defaults: defaults)
    }
}

/// Keeps the persistence contract independently testable without constructing
/// the full application runtime.
enum QuickReactionPreferences {
    static let key = "marmot.quickReactions"

    static func load(from defaults: UserDefaults) -> [String]? {
        defaults.stringArray(forKey: key)
            .map { QuickReactionChoices.normalize($0) }
    }

    @discardableResult
    static func save(_ choices: [String], to defaults: UserDefaults) -> [String] {
        let normalized = QuickReactionChoices.normalize(choices)
        defaults.set(normalized, forKey: key)
        return normalized
    }
}
