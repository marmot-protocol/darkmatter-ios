import Foundation
import Testing
import UIKit
import UniformTypeIdentifiers

@testable import whitenoise_ios

@MainActor
@Suite(.serialized)
struct RemoteImageLoaderTests {
    @Test func imageDataRejectsUnsanitizedURLsAtTheEgress() async throws {
        // Self-enforcing chokepoint: a caller that skips ContentSanitizer must
        // not reach the network on the first hop.
        let privateHost = try #require(URL(string: "https://127.0.0.1/a.png"))
        await #expect(throws: PinnedHTTPSFetcher.FetchError.invalidRequest) {
            try await RemoteImageFetch.imageData(for: privateHost)
        }
        let plainHTTP = try #require(URL(string: "http://example.com/a.png"))
        await #expect(throws: PinnedHTTPSFetcher.FetchError.invalidRequest) {
            try await RemoteImageFetch.imageData(for: plainHTTP)
        }
        let oddPort = try #require(URL(string: "https://example.com:8443/a.png"))
        await #expect(throws: PinnedHTTPSFetcher.FetchError.invalidRequest) {
            try await RemoteImageFetch.imageData(for: oddPort)
        }
    }

    @Test func remoteImageFetchDoesNotAdvertiseSVGContent() throws {
        let request = RemoteImageFetch.request(
            for: try #require(URL(string: "https://example.com/avatar.png")),
            accept: RemoteImageFetch.remoteImageAcceptHeader
        )
        let accept = try #require(request.value(forHTTPHeaderField: "Accept"))

        #expect(!accept.contains("image/svg+xml"))
        #expect(accept.contains("image/png"))
        #expect(accept.contains("image/jpeg"))
        #expect(accept.contains("image/webp"))
    }

    @Test func remoteImageDecoderRejectsSVGTypes() {
        #expect(RemoteImageDecoder.isAllowedRemoteImageType(UTType.png.identifier as CFString))
        #expect(RemoteImageDecoder.isAllowedRemoteImageType(UTType.jpeg.identifier as CFString))
        #expect(!RemoteImageDecoder.isAllowedRemoteImageType(UTType.svg.identifier as CFString))
        #expect(!RemoteImageDecoder.isAllowedRemoteImageType(nil))
    }

    @Test func avatarLoaderCachesFailuresWithTTLAndPreservesError() throws {
        let url = try #require(URL(string: "https://example.com/broken-avatar.png"))
        let now = Date()
        RemoteAvatarImageLoader.resetCachesForTesting()
        defer { RemoteAvatarImageLoader.resetCachesForTesting() }

        RemoteAvatarImageLoader.cacheFailureForTesting(URLError(.badServerResponse), for: url, now: now)

        let cached = try #require(
            RemoteAvatarImageLoader.cachedFailureForTesting(
                for: url,
                now: now.addingTimeInterval(30)
            ) as? URLError
        )
        #expect(cached.code == .badServerResponse)
        #expect(
            RemoteAvatarImageLoader.cachedFailureForTesting(
                for: url,
                now: now.addingTimeInterval(61)
            ) == nil
        )
        #expect(!RemoteAvatarImageLoader.shouldCacheFailureForTesting(CancellationError()))
        #expect(!RemoteAvatarImageLoader.shouldCacheFailureForTesting(URLError(.cancelled)))
        #expect(!RemoteAvatarImageLoader.shouldCacheFailureForTesting(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        ))
    }

    @Test func avatarLoaderCoalescesInFlightDataLoadsByURLKey() async throws {
        let url = try #require(URL(string: "https://example.com/avatar.png"))
        let data = Data([0xCA, 0xFE])
        let probe = RemoteImageFetchProbe(data: data)
        RemoteAvatarImageLoader.resetCachesForTesting()
        defer { RemoteAvatarImageLoader.resetCachesForTesting() }

        let first = Task { @MainActor in
            try await RemoteAvatarImageLoader.imageDataForTesting(
                for: url,
                keyString: url.absoluteString
            ) { _ in
                await probe.fetch()
            }
        }
        await probe.waitUntilStarted()

        let second = Task { @MainActor in
            try await RemoteAvatarImageLoader.imageDataForTesting(
                for: url,
                keyString: url.absoluteString
            ) { _ in
                await probe.fetch()
            }
        }

        // Let `second` run up to its in-flight coalescing await on the MainActor
        // before releasing the fetch. Otherwise `first` can complete and clear
        // the in-flight slot before `second` checks it, making `second` start a
        // second fetch and racing the single-fetch expectation.
        for _ in 0..<10 { await Task.yield() }

        await probe.release()
        let firstData = try await first.value
        let secondData = try await second.value

        #expect(firstData == data)
        #expect(secondData == data)
        #expect(await probe.callCount() == 1)
    }

    @Test func avatarDiskCacheSurvivesMemoryCacheResetAndExpiresOldEntries() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteAvatarDiskCacheTests-\(UUID().uuidString)", isDirectory: true)
        let cache = RemoteAvatarDiskCache(
            directoryURL: root,
            maximumBytes: 1_024,
            maximumEntryBytes: 128,
            maximumAge: 60
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try #require(URL(string: "https://example.com/persisted-avatar.png"))
        let data = Data([0x89, 0x50, 0x4E, 0x47])
        let writtenAt = Date(timeIntervalSince1970: 1_000)

        await cache.store(data, for: url, now: writtenAt)

        #expect(await cache.cachedFileExistsForTesting(for: url))
        #expect(await cache.data(for: url, now: writtenAt.addingTimeInterval(59)) == data)
        #expect(await cache.data(for: url, now: writtenAt.addingTimeInterval(120)) == nil)
        #expect(!(await cache.cachedFileExistsForTesting(for: url)))
    }

    @Test func avatarDiskCacheRejectsOversizedEntries() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteAvatarDiskCacheTests-\(UUID().uuidString)", isDirectory: true)
        let cache = RemoteAvatarDiskCache(
            directoryURL: root,
            maximumBytes: 1_024,
            maximumEntryBytes: 4,
            maximumAge: 60
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try #require(URL(string: "https://example.com/oversized-avatar.png"))

        await cache.store(Data(repeating: 0x01, count: 5), for: url)

        #expect(await cache.data(for: url) == nil)
        #expect(!(await cache.cachedFileExistsForTesting(for: url)))
    }

    @Test func avatarLoaderCacheCostExceedsCompressedBytesForHighlyCompressibleImage() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64), format: format)
        let image = renderer.image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        let compressedData = try #require(image.pngData())

        let cost = DecodedImageCost.decodedBitmapByteCost(for: image)

        #expect(cost == 64 * 64 * 4)
        #expect(cost > compressedData.count)
    }

    @Test func decoderDownsamplesLargeImages() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 80))
        let sourceImage = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
        }
        let data = try #require(sourceImage.pngData())

        let decoded = await RemoteImageDecoder.downsampledImage(from: data, maxPixelSize: 20, scale: 1)

        let image = try #require(decoded)
        #expect(max(image.size.width, image.size.height) <= 20)
    }

}

private actor RemoteImageFetchProbe {
    private let data: Data
    private var fetchCount = 0
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    init(data: Data) {
        self.data = data
    }

    func fetch() async -> Data {
        fetchCount += 1
        for waiter in startedWaiters {
            waiter.resume()
        }
        startedWaiters.removeAll()

        if !isReleased {
            await withCheckedContinuation { continuation in
                releaseWaiters.append(continuation)
            }
        }
        return data
    }

    func waitUntilStarted() async {
        guard fetchCount == 0 else { return }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func release() {
        isReleased = true
        for waiter in releaseWaiters {
            waiter.resume()
        }
        releaseWaiters.removeAll()
    }

    func callCount() -> Int {
        fetchCount
    }
}
