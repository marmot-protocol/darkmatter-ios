import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct ProfileRelayDiscoveryTests {
    @Test func usesOnlyMdkAllowedCanonicalRelayEndpoints() {
        let classifications = [
            RelayEndpointClassificationFfi(
                endpoint: "wss://allowed.example",
                normalizedEndpoint: "wss://allowed.example/",
                policy: .allowed
            ),
            RelayEndpointClassificationFfi(
                endpoint: "wss://relay.damus.io",
                normalizedEndpoint: "wss://relay.damus.io/",
                policy: .retired
            ),
            RelayEndpointClassificationFfi(
                endpoint: "ws://unsafe.example",
                normalizedEndpoint: "ws://unsafe.example/",
                policy: .unsafe
            ),
            RelayEndpointClassificationFfi(
                endpoint: "invalid",
                normalizedEndpoint: nil,
                policy: .invalid
            ),
        ]

        #expect(ProfileRelayDiscovery.allowedRelays(from: classifications) == [
            "wss://allowed.example/",
        ])
    }

    @Test func targetRelaysLeadBootstrapFallbackAndAreDeduplicated() {
        let relays = ProfileRelayDiscovery.profileRelays(
            targetRelays: ["wss://target.example", "wss://shared.example"],
            bootstrapRelays: ["wss://shared.example", "wss://bootstrap.example"]
        )

        #expect(relays == [
            "wss://target.example",
            "wss://shared.example",
            "wss://bootstrap.example",
        ])
    }

    @Test func missingTargetRouteTriggersDiscoveryEvenWithCachedProfile() {
        #expect(ProfileRelayDiscovery.shouldRefreshTargetRelayLists(
            cachedTargetRelays: [],
            hasRemoteIdentity: true
        ))
        #expect(ProfileRelayDiscovery.shouldRefreshTargetRelayLists(
            cachedTargetRelays: ["wss://target.example"],
            hasRemoteIdentity: false
        ))
        #expect(!ProfileRelayDiscovery.shouldRefreshTargetRelayLists(
            cachedTargetRelays: ["wss://target.example"],
            hasRemoteIdentity: true
        ))
    }
}
