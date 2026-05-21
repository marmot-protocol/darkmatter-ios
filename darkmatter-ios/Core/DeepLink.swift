import Foundation

/// Dark Matter deep links. Format: `darkmatter://profile/<npub>`.
///
/// Used both for the QR codes the app generates and for routing inbound
/// links — whether from the in-app scanner (which reads the raw string) or
/// the system (via `.onOpenURL`, once the URL scheme is registered in
/// Info.plist).
enum DeepLink: Equatable {
    case profile(npub: String)

    static let scheme = "darkmatter"

    var url: URL {
        switch self {
        case .profile(let npub):
            return URL(string: "\(Self.scheme)://profile/\(npub)")!
        }
    }

    /// Parse a `darkmatter://…` URL.
    static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        if url.host?.lowercased() == "profile", let npub = parts.first, npub.hasPrefix("npub") {
            return .profile(npub: npub)
        }
        // Tolerate darkmatter://<npub>
        if let host = url.host, host.hasPrefix("npub") {
            return .profile(npub: host)
        }
        return nil
    }

    /// Parse any scanned/pasted string: a deep-link URL, a `nostr:` URI, or a
    /// bare npub. Makes the scanner forgiving about QR payload formats.
    static func parse(string raw: String) -> DeepLink? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), let link = parse(url) {
            return link
        }
        if trimmed.lowercased().hasPrefix("nostr:") {
            let rest = String(trimmed.dropFirst("nostr:".count))
            if rest.hasPrefix("npub") { return .profile(npub: rest) }
        }
        if trimmed.hasPrefix("npub") {
            return .profile(npub: trimmed)
        }
        return nil
    }
}
