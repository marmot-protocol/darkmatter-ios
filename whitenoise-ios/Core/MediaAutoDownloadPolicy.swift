import Foundation
import Network

/// The kinds of media a bubble can carry. Each call site already knows its
/// own type (image bubble → `.image`, voice bubble → `.audio`), so the gate
/// is passed the literal type rather than re-deriving it from MIME.
nonisolated enum MediaAutoDownloadType: String, CaseIterable {
    case image
    case audio
    case video
    case document
}

/// The network conditions an auto-download decision is made against. A live
/// connection can match several at once (cellular that is also constrained);
/// the decision applies the most-restrictive matching rule. Mirrors the
/// Android client's matrix, minus its roaming row — this platform exposes no
/// public roaming signal, so the constrained/expensive flags stand in as the
/// "user is paying for data" condition.
nonisolated enum MediaAutoDownloadNetwork: String, CaseIterable {
    case wifi
    case mobile
    case metered

    /// Pure mapping from a live path's flags to every condition it matches.
    /// Wi-Fi that is expensive (a personal hotspot) counts as metered, as
    /// does any connection in Low Data Mode (`isConstrained`). Cellular is
    /// NOT automatically metered — the system flags all cellular as
    /// expensive, and stacking metered onto every mobile connection would
    /// make the mobile row meaningless. Empty means no/unknown connection,
    /// which `shouldAutoDownload` treats as "do not auto-download".
    static func matching(
        usesWifi: Bool,
        usesCellular: Bool,
        isExpensive: Bool,
        isConstrained: Bool
    ) -> Set<MediaAutoDownloadNetwork> {
        var networks: Set<MediaAutoDownloadNetwork> = []
        if usesWifi {
            networks.insert(.wifi)
            if isExpensive { networks.insert(.metered) }
        }
        if usesCellular {
            networks.insert(.mobile)
        }
        if isConstrained { networks.insert(.metered) }
        return networks
    }
}

/// Pure, immutable per-type × per-network auto-download matrix. Holds only
/// the set of enabled `(type, network)` cells; everything else is derived.
/// Decision semantics and serialization mirror the Android client so the
/// same stored preference means the same behavior on both platforms.
nonisolated struct MediaAutoDownloadMatrix: Equatable {
    private var enabled: Set<Cell>

    struct Cell: Hashable {
        let type: MediaAutoDownloadType
        let network: MediaAutoDownloadNetwork
    }

    init(enabled: Set<Cell>) {
        self.enabled = enabled
    }

    func isEnabled(_ type: MediaAutoDownloadType, on network: MediaAutoDownloadNetwork) -> Bool {
        enabled.contains(Cell(type: type, network: network))
    }

    func toggling(_ type: MediaAutoDownloadType, on network: MediaAutoDownloadNetwork, to on: Bool) -> Self {
        var next = enabled
        if on {
            next.insert(Cell(type: type, network: network))
        } else {
            next.remove(Cell(type: type, network: network))
        }
        return Self(enabled: next)
    }

    /// Most-restrictive decision: auto-download `type` only when
    /// `activeNetworks` is non-empty AND the type is enabled for every
    /// network the live connection matches — if metered is OFF for a type,
    /// that wins over Wi-Fi being ON. Empty (unknown/offline) is
    /// conservative: no auto-download.
    func shouldAutoDownload(
        _ type: MediaAutoDownloadType,
        activeNetworks: Set<MediaAutoDownloadNetwork>
    ) -> Bool {
        guard !activeNetworks.isEmpty else { return false }
        return activeNetworks.allSatisfy { isEnabled(type, on: $0) }
    }

    /// Flat, order-stable `type:network` CSV — the same wire format the
    /// Android client persists, so the preference is portable in meaning.
    func toPreference() -> String {
        MediaAutoDownloadType.allCases.flatMap { type in
            MediaAutoDownloadNetwork.allCases.compactMap { network in
                isEnabled(type, on: network) ? "\(type.rawValue):\(network.rawValue)" : nil
            }
        }
        .joined(separator: ",")
    }

    static func fromPreference(_ raw: String?) -> Self? {
        guard let raw else { return nil }
        var cells: Set<Cell> = []
        for pair in raw.split(separator: ",") {
            let parts = pair.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  let type = MediaAutoDownloadType(rawValue: String(parts[0])),
                  let network = MediaAutoDownloadNetwork(rawValue: String(parts[1]))
            else { continue }
            cells.insert(Cell(type: type, network: network))
        }
        return Self(enabled: cells)
    }

    /// Defaults shared with the Android client:
    /// Wi-Fi → images, audio, video (documents stay manual);
    /// Mobile → images, audio; Metered → images only.
    static let defaultMatrix = Self(enabled: [
        Cell(type: .image, network: .wifi),
        Cell(type: .audio, network: .wifi),
        Cell(type: .video, network: .wifi),
        Cell(type: .image, network: .mobile),
        Cell(type: .audio, network: .mobile),
        Cell(type: .image, network: .metered),
    ])
}

/// Persistence + live-network resolution for the matrix. Device-scoped like
/// the send-quality preference — download policy is a property of the device
/// and its connection.
@MainActor
@Observable
final class MediaAutoDownloadStore {
    static let shared = MediaAutoDownloadStore()
    static let storageKey = "media.autoDownloadMatrix"

    private(set) var matrix: MediaAutoDownloadMatrix
    private(set) var activeNetworks: Set<MediaAutoDownloadNetwork> = []
    private let defaults: UserDefaults
    private let monitor = NWPathMonitor()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.matrix = MediaAutoDownloadMatrix.fromPreference(defaults.string(forKey: Self.storageKey))
            ?? .defaultMatrix
        monitor.pathUpdateHandler = { [weak self] path in
            let networks = MediaAutoDownloadNetwork.matching(
                usesWifi: path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet),
                usesCellular: path.usesInterfaceType(.cellular),
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained
            )
            Task { @MainActor [weak self] in
                self?.activeNetworks = path.status == .satisfied ? networks : []
            }
        }
        monitor.start(queue: DispatchQueue(label: "media.autodownload.path"))
    }

    func setEnabled(_ type: MediaAutoDownloadType, on network: MediaAutoDownloadNetwork, to on: Bool) {
        matrix = matrix.toggling(type, on: network, to: on)
        defaults.set(matrix.toPreference(), forKey: Self.storageKey)
    }

    func shouldAutoDownload(_ type: MediaAutoDownloadType) -> Bool {
        matrix.shouldAutoDownload(type, activeNetworks: activeNetworks)
    }
}
