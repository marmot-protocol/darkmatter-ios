import Foundation
import Testing
@testable import whitenoise_ios

struct MediaAutoDownloadMatrixTests {
    @Test func mostRestrictiveNetworkWins() {
        let matrix = MediaAutoDownloadMatrix.defaultMatrix
        // Wi-Fi alone: video enabled by default.
        #expect(matrix.shouldAutoDownload(.video, activeNetworks: [.wifi]))
        // Wi-Fi that is also metered (hotspot / Low Data Mode): video is OFF
        // for metered, and the most restrictive condition wins.
        #expect(!matrix.shouldAutoDownload(.video, activeNetworks: [.wifi, .metered]))
        // Images are ON everywhere by default, so they survive the overlap.
        #expect(matrix.shouldAutoDownload(.image, activeNetworks: [.wifi, .metered]))
    }

    @Test func offlineOrUnknownNeverAutoDownloads() {
        let matrix = MediaAutoDownloadMatrix.defaultMatrix
        #expect(!matrix.shouldAutoDownload(.image, activeNetworks: []))
    }

    @Test func defaultsMirrorTheSharedMatrix() {
        let matrix = MediaAutoDownloadMatrix.defaultMatrix
        // Wi-Fi: everything except documents.
        #expect(matrix.isEnabled(.image, on: .wifi))
        #expect(matrix.isEnabled(.audio, on: .wifi))
        #expect(matrix.isEnabled(.video, on: .wifi))
        #expect(!matrix.isEnabled(.document, on: .wifi))
        // Mobile: images and audio.
        #expect(matrix.isEnabled(.image, on: .mobile))
        #expect(matrix.isEnabled(.audio, on: .mobile))
        #expect(!matrix.isEnabled(.video, on: .mobile))
        // Metered: images only.
        #expect(matrix.isEnabled(.image, on: .metered))
        #expect(!matrix.isEnabled(.audio, on: .metered))
    }

    @Test func preferenceRoundTripsAndIgnoresUnknownCells() {
        let matrix = MediaAutoDownloadMatrix.defaultMatrix
            .toggling(.document, on: .wifi, to: true)
            .toggling(.image, on: .metered, to: false)
        let restored = MediaAutoDownloadMatrix.fromPreference(matrix.toPreference())
        #expect(restored == matrix)
        // Unknown tokens (a future platform's rows) parse without error.
        let partial = MediaAutoDownloadMatrix.fromPreference("image:wifi,video:roaming,garbage")
        #expect(partial?.isEnabled(.image, on: .wifi) == true)
    }

    @Test func networkMatchingStacksConditions() {
        // Hotspot: Wi-Fi transport flagged expensive.
        #expect(MediaAutoDownloadNetwork.matching(
            usesWifi: true, usesCellular: false, isExpensive: true, isConstrained: false
        ) == [.wifi, .metered])
        // Ordinary cellular is mobile only — the system flags all cellular
        // as expensive, and stacking metered would erase the mobile row.
        #expect(MediaAutoDownloadNetwork.matching(
            usesWifi: false, usesCellular: true, isExpensive: true, isConstrained: false
        ) == [.mobile])
        // Low Data Mode stacks metered onto any transport.
        #expect(MediaAutoDownloadNetwork.matching(
            usesWifi: false, usesCellular: true, isExpensive: true, isConstrained: true
        ) == [.mobile, .metered])
        #expect(MediaAutoDownloadNetwork.matching(
            usesWifi: false, usesCellular: false, isExpensive: false, isConstrained: false
        ).isEmpty)
    }
}

struct MediaQualityTests {
    @Test func levelsCarryTheSharedKnobs() {
        #expect(MediaQuality.low.imageMaxEdgePx == 1024)
        #expect(MediaQuality.standard.imageMaxEdgePx == 2048)
        #expect(MediaQuality.high.imageMaxEdgePx == 4096)
        #expect(MediaQuality.original.imageMaxEdgePx == .greatestFiniteMagnitude)
        #expect(MediaQuality.low.audioBitrateBps == 32_000)
        #expect(MediaQuality.standard.audioBitrateBps == 64_000)
        #expect(MediaQuality.high.audioBitrateBps == 96_000)
        #expect(MediaQuality.defaultQuality == .standard)
    }

    @Test func jpegLadderDescendsFromTheLevelCeilingToTheFloor() {
        for level in MediaQuality.allCases {
            let ladder = level.imageJPEGQualityLadder
            #expect(ladder.first == level.imageJPEGQuality)
            #expect(ladder.last == 0.52)
            #expect(ladder == ladder.sorted(by: >))
        }
    }

    @Test func storeRoundTripsAndDefaultsToStandard() {
        let suiteName = "media-quality-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        #expect(MediaQualityStore.quality(defaults: defaults) == .standard)
        MediaQualityStore.setQuality(.original, defaults: defaults)
        #expect(MediaQualityStore.quality(defaults: defaults) == .original)
    }
}
