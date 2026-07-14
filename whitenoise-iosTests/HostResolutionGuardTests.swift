import Foundation
import Testing
@testable import whitenoise_ios

/// The DNS-resolution SSRF gate: a public-looking host that resolves to a
/// private/loopback/link-local address must be refused, while a genuinely
/// public or unresolvable host is not blocked. Uses an injected resolver so no
/// real DNS is involved.
struct HostResolutionGuardTests {

    @Test func publicResolvedAddressIsAllowed() {
        let resolver: HostResolutionGuard.Resolver = { _ in ["93.184.216.34"] }
        #expect(!HostResolutionGuard.resolvesToPrivateAddress("example.com", resolver: resolver))
    }

    @Test func loopbackResolvedAddressIsBlocked() {
        let resolver: HostResolutionGuard.Resolver = { _ in ["127.0.0.1"] }
        #expect(HostResolutionGuard.resolvesToPrivateAddress("127-0-0-1.nip.io", resolver: resolver))
    }

    @Test func privateResolvedAddressIsBlocked() {
        let resolver: HostResolutionGuard.Resolver = { _ in ["10.0.0.5"] }
        #expect(HostResolutionGuard.resolvesToPrivateAddress("10-0-0-5.sslip.io", resolver: resolver))
    }

    @Test func linkLocalMetadataAddressIsBlocked() {
        let resolver: HostResolutionGuard.Resolver = { _ in ["169.254.169.254"] }
        #expect(HostResolutionGuard.resolvesToPrivateAddress("metadata.example", resolver: resolver))
    }

    @Test func ipv6LoopbackResolvedAddressIsBlocked() {
        let resolver: HostResolutionGuard.Resolver = { _ in ["::1"] }
        #expect(HostResolutionGuard.resolvesToPrivateAddress("evil.example", resolver: resolver))
    }

    @Test func anyPrivateAddressInMixedResolutionIsBlocked() {
        // Round-robin DNS that mixes a public and a private answer must fail
        // closed on the private one.
        let resolver: HostResolutionGuard.Resolver = { _ in ["93.184.216.34", "192.168.1.10"] }
        #expect(HostResolutionGuard.resolvesToPrivateAddress("rebind.example", resolver: resolver))
    }

    @Test func unresolvableHostIsNotBlocked() {
        // Nothing resolved: don't pre-block — the real fetch fails on its own.
        let resolver: HostResolutionGuard.Resolver = { _ in [] }
        #expect(!HostResolutionGuard.resolvesToPrivateAddress("nxdomain.example", resolver: resolver))
    }
}
