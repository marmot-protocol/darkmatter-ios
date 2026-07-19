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

    @Test func defaultsMatchTheReferenceLevels() {
        let matrix = MediaAutoDownloadMatrix.defaultMatrix
        #expect(matrix.level(for: .image) == .wifiAndCellular)
        #expect(matrix.level(for: .audio) == .wifiAndCellular)
        #expect(matrix.level(for: .video) == .wifiOnly)
        #expect(matrix.level(for: .document) == .wifiOnly)
    }

    @Test func levelsProjectOntoCanonicalNetworkSets() {
        var matrix = MediaAutoDownloadMatrix(enabled: [])
        matrix = matrix.setting(.video, to: .wifiAndCellular)
        #expect(matrix.isEnabled(.video, on: .wifi))
        #expect(matrix.isEnabled(.video, on: .mobile))
        #expect(matrix.isEnabled(.video, on: .metered))
        matrix = matrix.setting(.video, to: .wifiOnly)
        #expect(matrix.isEnabled(.video, on: .wifi))
        #expect(!matrix.isEnabled(.video, on: .mobile))
        #expect(!matrix.isEnabled(.video, on: .metered))
        matrix = matrix.setting(.video, to: .never)
        #expect(matrix.level(for: .video) == .never)
        // Setting one type never disturbs another's cells.
        #expect(matrix.setting(.image, to: .wifiAndCellular).level(for: .video) == .never)
    }

    @Test func legacyPerCellMatricesSnapToASensibleLevel() {
        // A matrix written by the earlier per-cell surface: mobile enabled
        // without metered still reads as everywhere; wifi-only cells read as
        // Wi-Fi; a stray metered-only cell reads as never.
        let legacy = MediaAutoDownloadMatrix.fromPreference("image:wifi,image:mobile,audio:wifi,video:metered")
        #expect(legacy?.level(for: .image) == .wifiAndCellular)
        #expect(legacy?.level(for: .audio) == .wifiOnly)
        #expect(legacy?.level(for: .video) == .never)
        #expect(legacy?.level(for: .document) == .never)
    }

    @Test func voiceBypassRequiresAPlausibleKnownDuration() {
        // Unknown or implausible metadata honors the matrix — an explicit
        // Never must win over an unverifiable voice guess.
        #expect(AudioAutoDownloadPolicy.isVoiceMessage(durationSeconds: 12.5))
        #expect(!AudioAutoDownloadPolicy.isVoiceMessage(durationSeconds: nil))
        #expect(!AudioAutoDownloadPolicy.isVoiceMessage(durationSeconds: 0))
        #expect(!AudioAutoDownloadPolicy.isVoiceMessage(durationSeconds: 3_600))
        #expect(!AudioAutoDownloadPolicy.isVoiceMessage(durationSeconds: .infinity))
        #expect(AudioAutoDownloadPolicy.shouldPrefetch(isVoiceMessage: true, matrixAllows: false))
        #expect(AudioAutoDownloadPolicy.shouldPrefetch(isVoiceMessage: false, matrixAllows: true))
        #expect(!AudioAutoDownloadPolicy.shouldPrefetch(isVoiceMessage: false, matrixAllows: false))
    }

    @Test @MainActor func matrixPreferenceIsScopedPerAccount() {
        let suiteName = "media-matrix-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = MediaAutoDownloadStore(defaults: defaults)
        store.setActiveAccount("aaaa")
        store.setLevel(.never, for: .image)
        #expect(store.matrix.level(for: .image) == .never)

        // A different account starts from defaults; switching back restores
        // the first account's choice.
        store.setActiveAccount("bbbb")
        #expect(store.matrix.level(for: .image) == .wifiAndCellular)
        store.setActiveAccount("aaaa")
        #expect(store.matrix.level(for: .image) == .never)
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
