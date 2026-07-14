/// Static donation methods for the Donate screen. The addresses are the
/// project's public funding endpoints and must stay byte-identical to the
/// values the Android client ships, so both apps present the same QR.
nonisolated enum DonatePresentation {

    struct Method: Equatable, Identifiable {
        let id: String
        let address: String

        /// Middle-truncated form for the one-line monospaced row — copy and
        /// QR paths always carry the full address.
        var displayAddress: String {
            IdentityFormatter.short(address, head: 18, tail: 12)
        }

        /// Bare address with no URI scheme, matching the Android client's QR
        /// payload so both codes scan identically.
        var qrPayload: String { address }
    }

    static let lightning = Method(
        id: "lightning",
        address: "whitenoise@donate.ipf.dev"
    )

    static let bitcoinSilentPayment = Method(
        id: "bitcoin-silent-payment",
        address: "sp1qqvp56mxcj9pz9xudvlch5g4ah5hrc8rj6neu25p34rc9gxhp38cwqqlmld28u57w2srgckr34dkyg3q02phu8tm05cyj483q026xedp0s5f5j40p"
    )

    static let methods = [lightning, bitcoinSilentPayment]
}
