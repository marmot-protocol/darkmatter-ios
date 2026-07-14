import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

nonisolated enum RemoteImageFetch {
    static let maximumImageBytes = 2 * 1024 * 1024
    /// Byte cap for non-image responses (e.g. the DuckDuckGo image-search
    /// JSON/HTML fetched via `data(for:)`). Mirrors `maximumImageBytes` so a
    /// hostile/oversized search response cannot be buffered unbounded into
    /// memory. Larger than `maximumImageBytes` because a search payload can
    /// legitimately exceed a single thumbnail's size.
    static let maximumResponseBytes = 8 * 1024 * 1024
    static let remoteImageAcceptHeader = [
        "image/avif",
        "image/webp",
        "image/apng",
        "image/png",
        "image/jpeg",
        "image/gif",
        "image/heic",
        "image/heif",
        "*/*;q=0.8",
    ].joined(separator: ",")

    static func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        // The pinned transport receives whole network chunks and rejects the
        // response as soon as headers plus body exceed the configured cap.
        return try await download(request, maximumResponseBytes: maximumResponseBytes)
    }

    static func imageData(for url: URL) async throws -> Data {
        let request = request(
            for: url,
            accept: remoteImageAcceptHeader
        )
        let (data, _) = try await download(request, maximumResponseBytes: maximumImageBytes)
        return data
    }

    private static func download(
        _ request: URLRequest,
        maximumResponseBytes cap: Int
    ) async throws -> (Data, URLResponse) {
        // Resolve exactly once and connect to that validated numeric address.
        // Keeping the original host only for HTTP Host and TLS SNI closes the
        // DNS-rebinding gap between a preflight lookup and URLSession's lookup.
        try await PinnedHTTPSFetcher.fetch(request, maximumResponseBytes: cap)
    }

    static func request(for url: URL, accept: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 12
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        return request
    }

}

nonisolated enum RemoteImageDecoder {
    static func isAllowedRemoteImageType(_ typeIdentifier: CFString?) -> Bool {
        guard let typeIdentifier,
              let type = UTType(typeIdentifier as String)
        else { return false }
        return type.conforms(to: .image) && !type.conforms(to: UTType.svg)
    }

    static func downsampledImage(from data: Data, maxPixelSize: Int, scale: CGFloat) async -> UIImage? {
        let targetPixelSize = max(maxPixelSize, 1)
        let imageScale = max(scale, 1)
        return await Task.detached(priority: .utility) { () -> UIImage? in
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
                return nil
            }
            guard Self.isAllowedRemoteImageType(CGImageSourceGetType(source)) else {
                return nil
            }
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: targetPixelSize,
            ] as CFDictionary
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
                return nil
            }
            return UIImage(cgImage: cgImage, scale: imageScale, orientation: .up)
        }.value
    }
}

nonisolated enum DecodedImageCost {
    static func decodedBitmapByteCost(for image: UIImage) -> Int {
        if let cgImage = image.cgImage {
            let cost = cgImage.bytesPerRow.multipliedReportingOverflow(by: cgImage.height)
            return cost.overflow ? Int.max : max(1, cost.partialValue)
        }
        let pixelWidth = max(1, Int(ceil(image.size.width * image.scale)))
        let pixelHeight = max(1, Int(ceil(image.size.height * image.scale)))
        let pixels = pixelWidth.multipliedReportingOverflow(by: pixelHeight)
        guard !pixels.overflow else { return Int.max }
        let bytes = pixels.partialValue.multipliedReportingOverflow(by: 4)
        return bytes.overflow ? Int.max : max(1, bytes.partialValue)
    }
}

@MainActor
enum RemoteAvatarImageLoader {
    private final class CachedImage: NSObject {
        let image: UIImage

        init(image: UIImage) {
            self.image = image
        }
    }

    private final class CachedFailure: NSObject {
        let error: Error
        let expiresAt: Date

        init(error: Error, expiresAt: Date) {
            self.error = error
            self.expiresAt = expiresAt
        }

        func isExpired(now: Date = Date()) -> Bool {
            now >= expiresAt
        }
    }

    /// Short negative-cache window: long enough to dampen layout/scroll retry
    /// storms, short enough that a transiently broken avatar can recover soon.
    private static let failureCacheTTL: TimeInterval = 60
    /// Bound peer-controlled bad URL churn independently from decoded-image cost.
    private static let failureCacheCountLimit = 500

    private static let cache: NSCache<NSString, CachedImage> = {
        let cache = NSCache<NSString, CachedImage>()
        cache.totalCostLimit = 20 * 1024 * 1024
        return cache
    }()

    private static let failureCache: NSCache<NSString, CachedFailure> = {
        let cache = NSCache<NSString, CachedFailure>()
        cache.countLimit = failureCacheCountLimit
        return cache
    }()

    private static var inFlightTasks: [String: Task<Data, Error>] = [:]

    static func image(for url: URL, maxPixelSize: Int, scale: CGFloat) async throws -> UIImage {
        let targetPixelSize = max(maxPixelSize, 1)
        let key = cacheKey(for: url, maxPixelSize: targetPixelSize)
        let failureKey = failureCacheKey(for: url)
        let failureKeyString = failureKey as String
        if let cached = cache.object(forKey: key)?.image {
            return cached
        }

        if let cachedFailure = cachedFailureError(for: failureKey) {
            throw cachedFailure
        }

        do {
            let data = try await imageData(for: url, keyString: failureKeyString)
            guard let image = await RemoteImageDecoder.downsampledImage(
                from: data,
                maxPixelSize: targetPixelSize,
                scale: scale
            ) else { throw URLError(.cannotDecodeContentData) }

            failureCache.removeObject(forKey: failureKey)
            cache.setObject(
                CachedImage(image: image),
                forKey: key,
                cost: DecodedImageCost.decodedBitmapByteCost(for: image)
            )
            return image
        } catch {
            cacheFailure(error, for: failureKey)
            throw error
        }
    }

    private static func imageData(for url: URL, keyString: String) async throws -> Data {
        try await imageData(for: url, keyString: keyString) { url in
            try await RemoteImageFetch.imageData(for: url)
        }
    }

    private static func imageData(
        for url: URL,
        keyString: String,
        fetch: @escaping @Sendable (URL) async throws -> Data
    ) async throws -> Data {
        if let inFlightTask = inFlightTasks[keyString] {
            // A just-completed task may still be present until its owner resumes
            // and clears the slot; reusing that result is safe and still avoids
            // a redundant fetch for simultaneous rows.
            return try await inFlightTask.value
        }

        let task = Task {
            try await fetch(url)
        }
        inFlightTasks[keyString] = task
        defer { inFlightTasks[keyString] = nil }
        return try await task.value
    }

    private static func cachedFailureError(for key: NSString, now: Date = Date()) -> Error? {
        guard let cachedFailure = failureCache.object(forKey: key) else { return nil }
        if cachedFailure.isExpired(now: now) {
            failureCache.removeObject(forKey: key)
            return nil
        }
        return cachedFailure.error
    }

    private static func cacheFailure(_ error: Error, for key: NSString, now: Date = Date()) {
        guard shouldCacheFailure(error) else { return }
        failureCache.setObject(
            CachedFailure(error: error, expiresAt: now.addingTimeInterval(failureCacheTTL)),
            forKey: key
        )
    }

    private static func shouldCacheFailure(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if (error as? URLError)?.code == .cancelled { return false }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled { return false }
        return true
    }

    private static func cacheKey(for url: URL, maxPixelSize: Int) -> NSString {
        "\(url.absoluteString):\(maxPixelSize)" as NSString
    }

    private static func failureCacheKey(for url: URL) -> NSString {
        url.absoluteString as NSString
    }

    #if DEBUG
    static func resetCachesForTesting() {
        cache.removeAllObjects()
        failureCache.removeAllObjects()
        inFlightTasks.removeAll()
    }

    static func cacheFailureForTesting(_ error: Error, for url: URL, now: Date = Date()) {
        cacheFailure(error, for: failureCacheKey(for: url), now: now)
    }

    static func cachedFailureForTesting(for url: URL, now: Date = Date()) -> Error? {
        cachedFailureError(for: failureCacheKey(for: url), now: now)
    }

    static func shouldCacheFailureForTesting(_ error: Error) -> Bool {
        shouldCacheFailure(error)
    }

    static func imageDataForTesting(
        for url: URL,
        keyString: String,
        fetch: @escaping @Sendable (URL) async throws -> Data
    ) async throws -> Data {
        try await imageData(for: url, keyString: keyString, fetch: fetch)
    }
    #endif
}
