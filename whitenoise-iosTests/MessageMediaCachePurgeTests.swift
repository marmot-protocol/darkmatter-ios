import Foundation
import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct MessageMediaCachePurgeTests {
    @Test func staleProducerCannotStorePlaintextAfterAPurge() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-race-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reference = purgeTestReference()
        let url = try #require(MessageMediaCache.cacheURL(for: reference, cachesDirectory: root))

        // Deterministic ordering of the reviewed race: the producer captures
        // its epoch, the wipe completes, and only then does the store run —
        // it must be rejected before touching the filesystem.
        let staleEpoch = MessageMediaCache.currentProducerEpoch()
        #expect(MessageMediaCache.purgeAllDecryptedMedia(cachesDirectory: root))
        MessageMediaCache.store(
            Data([0x1]),
            for: reference,
            cachesDirectory: root,
            producerGeneration: staleEpoch
        )
        #expect(!FileManager.default.fileExists(atPath: url.path))

        // A producer whose epoch postdates the purge stores normally. The
        // epoch is process-global, so tolerate another suite's purge landing
        // in the capture-to-store window instead of flaking.
        var storedFresh = false
        for _ in 0..<3 where !storedFresh {
            let freshEpoch = MessageMediaCache.currentProducerEpoch()
            MessageMediaCache.store(
                Data([0x1]),
                for: reference,
                cachesDirectory: root,
                producerGeneration: freshEpoch
            )
            storedFresh = FileManager.default.fileExists(atPath: url.path)
        }
        #expect(storedFresh)

        // The purge removes what exists and reports it.
        #expect(MessageMediaCache.purgeAllDecryptedMedia(cachesDirectory: root))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func playbackWritesRejectStaleProducersToo() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("purge-race-playback-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // No reference: this exercises the raw playback branch.
        let item = MessageMediaAttachment(
            id: "playback-item",
            reference: nil,
            fileName: "voice.m4a",
            mediaType: "audio/mp4",
            dim: nil,
            localData: nil
        )

        let staleEpoch = MessageMediaCache.currentProducerEpoch()
        #expect(MessageMediaCache.purgeAllDecryptedMedia(cachesDirectory: root))
        let rejected = MediaPlaybackFileStore.fileURL(
            for: item,
            data: Data([0x2]),
            cachesDirectory: root,
            mediaPolicy: .media,
            playbackPolicy: .playback,
            producerEpoch: staleEpoch
        )
        #expect(rejected == nil)

        var freshURL: URL?
        for _ in 0..<3 where freshURL == nil {
            freshURL = MediaPlaybackFileStore.fileURL(
                for: item,
                data: Data([0x2]),
                cachesDirectory: root,
                mediaPolicy: .media,
                playbackPolicy: .playback,
                producerEpoch: MessageMediaCache.currentProducerEpoch()
            )
        }
        #expect(freshURL != nil)
    }
}

private func purgeTestReference() -> MediaAttachmentReferenceFfi {
    MediaAttachmentReferenceFfi(
        locators: [MediaLocatorFfi(kind: "blossom-v1", value: "https://example.com/media")],
        ciphertextSha256: String(repeating: "a", count: 64),
        plaintextSha256: String(repeating: "b", count: 64),
        nonceHex: String(repeating: "2", count: 24),
        fileName: "photo.jpg",
        mediaType: "image/jpeg",
        version: MessageSemantics.encryptedMediaVersion,
        sourceEpoch: 1,
        dim: nil,
        thumbhash: nil
    )
}
