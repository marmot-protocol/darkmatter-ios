import Foundation

/// Dark Matter deep links. Formats: `darkmatter://profile/<npub>` and
/// `darkmatter://chat/<groupIdHex>`.
///
/// Used both for the QR codes the app generates and for routing inbound
/// links — whether from the in-app scanner (which reads the raw string) or
/// the system (via `.onOpenURL`, once the URL scheme is registered in
/// Info.plist).
enum DeepLink: Equatable {
    case profile(npub: String)
    case chat(groupIdHex: String)

    static let scheme = "darkmatter"

    var url: URL {
        switch self {
        case .profile(let npub):
            return URL(string: "\(Self.scheme)://profile/\(npub)")!
        case .chat(let groupIdHex):
            return URL(string: "\(Self.scheme)://chat/\(groupIdHex)")!
        }
    }

    /// Parse a `darkmatter://…` URL.
    static func parse(_ url: URL) -> DeepLink? {
        guard url.scheme?.lowercased() == scheme else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch url.host?.lowercased() {
        case "profile":
            if let npub = parts.first, npub.hasPrefix("npub") { return .profile(npub: npub) }
        case "chat":
            if let id = parts.first, isHex(id) { return .chat(groupIdHex: id.lowercased()) }
        default:
            break
        }
        // Tolerate darkmatter://<npub>
        if let host = url.host, host.hasPrefix("npub") {
            return .profile(npub: host)
        }
        return nil
    }

    private static func isHex(_ s: String) -> Bool {
        !s.isEmpty && s.range(of: "^[0-9a-fA-F]+$", options: .regularExpression) != nil
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
