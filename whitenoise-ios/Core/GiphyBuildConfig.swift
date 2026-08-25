import Foundation

nonisolated struct GiphyBuildConfig: Equatable, Sendable {
    static let infoDictionaryKey = "WhiteNoiseGiphyAPIKey"

    let apiKey: String?

    static func current(
        infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]
    ) -> GiphyBuildConfig {
        let raw = infoDictionary[infoDictionaryKey] as? String
        let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
        return GiphyBuildConfig(apiKey: key?.isEmpty == false ? key : nil)
    }

    var isAvailable: Bool { apiKey != nil }
}
