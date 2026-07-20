import Foundation
import MarmotKit

/// Defense in depth for peer-controlled encrypted-media locators. Marmot owns
/// decryption and hash verification; the client refuses to hand it a cleartext,
/// local-network, malformed, or DNS-to-private Blossom target.
nonisolated enum EncryptedMediaLocatorValidation {
    static let blossomKind = "blossom-v1"

    static func validatedURL(for locator: MediaLocatorFfi) -> URL? {
        guard locator.kind == blossomKind,
              let url = ContentSanitizer.imageURL(locator.value),
              let host = url.host?.lowercased()
        else { return nil }
        let canonicalHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard canonicalHost != "localhost", !canonicalHost.hasSuffix(".localhost") else { return nil }
        return url
    }

    /// Unsupported locator kinds are ignored because the engine cannot fetch
    /// them. At least one Blossom locator must exist, and every Blossom locator
    /// must pass the static URL allowlist so a safe decoy cannot hide an unsafe
    /// fallback target.
    static func isStaticallySafe(_ locators: [MediaLocatorFfi]) -> Bool {
        let fetchable = locators.filter { $0.kind == blossomKind }
        return !fetchable.isEmpty && fetchable.allSatisfy { validatedURL(for: $0) != nil }
    }

    /// Resolve every fetchable host immediately before native download. Empty
    /// resolution fails closed because the target cannot be proven public.
    static func resolvesOnlyToPublicAddresses(
        _ locators: [MediaLocatorFfi],
        resolver: HostResolutionGuard.Resolver = HostResolutionGuard.systemResolver
    ) -> Bool {
        guard isStaticallySafe(locators) else { return false }
        let hosts = Set(locators.compactMap { locator in
            validatedURL(for: locator)?.host?.lowercased()
        })
        return hosts.allSatisfy { host in
            (try? HostResolutionGuard.resolvedPublicAddresses(host, resolver: resolver)) != nil
        }
    }
}
