import Foundation
import ImageIO
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import whitenoise_ios

struct GiphyIntegrationTests {
    @MainActor
    @Test func animatedGIFViewHasNoIntrinsicPixelSize() {
        let view = GiphyAnimatedImageUIView(frame: .zero)

        #expect(view.intrinsicContentSize.width == UIView.noIntrinsicMetric)
        #expect(view.intrinsicContentSize.height == UIView.noIntrinsicMetric)
        #expect(view.contentCompressionResistancePriority(for: .horizontal) == .defaultLow)
        #expect(view.contentCompressionResistancePriority(for: .vertical) == .defaultLow)
    }

    @Test func legacyLookupOnlyRetriesTransientResolutionFailure() {
        #expect(GiphySearchClient.shouldRetryLookup(
            error: HostResolutionGuard.GuardError.resolutionFailed,
            retryCount: 0
        ))
        #expect(!GiphySearchClient.shouldRetryLookup(
            error: HostResolutionGuard.GuardError.resolutionFailed,
            retryCount: 2
        ))
        #expect(!GiphySearchClient.shouldRetryLookup(
            error: HostResolutionGuard.GuardError.resolvesToPrivateAddress,
            retryCount: 0
        ))
        #expect(!GiphySearchClient.shouldRetryLookup(
            error: URLError(.badServerResponse),
            retryCount: 0
        ))
    }

    @Test func animatedGIFReadsDimensionsFromItsFirstFrame() throws {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            data,
            UTType.gif.identifier as CFString,
            2,
            nil
        ))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(
            data: nil,
            width: 2,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 8,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
        let firstFrame = try #require(context.makeImage())
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 1))
        let secondFrame = try #require(context.makeImage())
        let frameProperties = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFDelayTime: 0.1,
            ],
        ] as CFDictionary
        CGImageDestinationAddImage(destination, firstFrame, frameProperties)
        CGImageDestinationAddImage(destination, secondFrame, frameProperties)
        #expect(CGImageDestinationFinalize(destination))

        let aspectRatio = try GiphyRemoteMediaLoader.animatedImageAspectRatio(from: data as Data)

        #expect(aspectRatio == 2)
    }

    @Test func buildConfigTreatsMissingAndWhitespaceKeysAsUnavailable() {
        #expect(!GiphyBuildConfig.current(infoDictionary: [:]).isAvailable)
        #expect(!GiphyBuildConfig.current(infoDictionary: [
            GiphyBuildConfig.infoDictionaryKey: "  \n",
        ]).isAvailable)
        #expect(GiphyBuildConfig.current(infoDictionary: [
            GiphyBuildConfig.infoDictionaryKey: "  test-key  ",
        ]).apiKey == "test-key")
    }

    @Test func wireTextRoundTripsTheExactGiphyURLAndCredit() throws {
        let url = try #require(URL(string: "https://media1.giphy.com/media/abc/giphy.mp4?cid=client&rid=giphy.mp4"))
        let media = RemoteGiphyMedia(url: url, width: 480, height: 270, attribution: "Creator")

        let parsed = try #require(RemoteGiphyMedia.parse(wireText: media.wireText))

        #expect(parsed.url.absoluteString == url.absoluteString)
        #expect(parsed.attribution == "Creator")
    }

    @Test(arguments: [
        "http://media.giphy.com/media/abc/giphy.mp4",
        "https://giphy.com/media/abc/giphy.mp4",
        "https://media.giphy.com.evil.example/media/abc/giphy.mp4",
        "https://user@media.giphy.com/media/abc/giphy.mp4",
        "https://media.giphy.com:443/media/abc/giphy.mp4",
        "https://media.giphy.com/media/abc/index.html",
    ])
    func rejectsUnsafeOrNonMediaURLs(_ rawURL: String) {
        #expect(RemoteGiphyMedia.validatedMediaURL(rawURL) == nil)
    }

    @Test func wireParserRejectsExtraOrMalformedMetadata() {
        let url = "https://media.giphy.com/media/abc/giphy.mp4"
        #expect(RemoteGiphyMedia.parse(wireText: url) == nil)
        #expect(RemoteGiphyMedia.parse(wireText: "\(url)\nnot GIPHY") == nil)
        #expect(RemoteGiphyMedia.parse(wireText: "\(url)\nvia GIPHY\nextra") == nil)
        #expect(RemoteGiphyMedia.parse(wireText: "\(url)\nvia GIPHY · \(String(repeating: "a", count: 81))") == nil)
    }

    @Test func searchRequestKeepsTheQueryAndUsesThePrivacyTransportPolicy() throws {
        let request = try #require(GiphySearchClient.searchRequest(
            query: "tiny cats & dogs",
            apiKey: "test-key",
            locale: Locale(identifier: "pt_PT")
        ))
        let requestURL = try #require(request.url)
        let components = try #require(URLComponents(url: requestURL, resolvingAgainstBaseURL: false))
        let values = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item in
            item.value.map { (item.name, $0) }
        })

        #expect(components.scheme == "https")
        #expect(components.host == "api.giphy.com")
        #expect(components.path == "/v1/gifs/search")
        #expect(values["q"] == "tiny cats & dogs")
        #expect(values["api_key"] == "test-key")
        #expect(values["rating"] == "pg-13")
        #expect(values["bundle"] == "messaging_non_clips")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.httpShouldHandleCookies == false)
    }

    @Test func decoderPreservesReturnedMediaURLAndRejectsOversizedRenditions() throws {
        let json = #"""
        {
          "data": [
            {
              "id": "accepted",
              "title": "A GIF",
              "username": "fallback",
              "user": { "username": "creator", "display_name": "Creator Name" },
              "images": {
                "fixed_width": {
                  "width": "480", "height": "270", "size": "4096",
                  "url": "https://media2.giphy.com/media/accepted/giphy.gif?cid=client&rid=giphy.gif",
                  "mp4_size": "2048",
                  "mp4": "https://media2.giphy.com/media/accepted/giphy.mp4?cid=client&rid=giphy.mp4"
                },
                "fixed_width_small_still": {
                  "url": "https://media2.giphy.com/media/accepted/100w.gif?cid=client&rid=100w.gif"
                }
              }
            },
            {
              "id": "too-large",
              "title": "Too large",
              "username": "",
              "images": {
                "fixed_width": {
                  "width": "480", "height": "270", "size": "999999999",
                  "url": "https://media.giphy.com/media/large/giphy.gif",
                  "mp4_size": "1024",
                  "mp4": "https://media.giphy.com/media/large/giphy.mp4"
                },
                "fixed_width_small_still": {
                  "url": "https://media.giphy.com/media/large/100w.gif"
                }
              }
            }
          ]
        }
        """#

        let results = try GiphySearchClient.decodeResults(from: Data(json.utf8))

        #expect(results.count == 1)
        #expect(results.first?.id == "accepted")
        #expect(results.first?.media.url.absoluteString == "https://media2.giphy.com/media/accepted/giphy.gif?cid=client&rid=giphy.gif")
        #expect(results.first?.media.attribution == "Creator Name")
        #expect(results.first?.media.width == 480)
        #expect(results.first?.media.height == 270)
    }

    @Test func decoderPrefersAnimatedImageFromCurrentMessagingBundle() throws {
        let json = #"""
        {
          "data": [{
            "id": "current-bundle",
            "title": "Current bundle",
            "username": "creator",
            "source_tld": "example.com",
            "images": {
              "original": {
                "url": "https://media3.giphy.com/media/current/giphy.gif",
                "width": "480", "height": "270", "size": "681862",
                "mp4_size": "400380",
                "mp4": "https://media3.giphy.com/media/current/giphy.mp4"
              },
              "fixed_width": {
                "url": "https://media3.giphy.com/media/current/200w.gif",
                "width": "200", "height": "113", "mp4_size": "136382",
                "mp4": "https://media3.giphy.com/media/current/200w.mp4"
              },
              "fixed_width_small": {
                "url": "https://media3.giphy.com/media/current/100w.gif",
                "width": "100", "height": "57"
              }
            }
          }]
        }
        """#

        let results = try GiphySearchClient.decodeResults(from: Data(json.utf8))

        #expect(results.count == 1)
        #expect(results.first?.media.url.absoluteString == "https://media3.giphy.com/media/current/giphy.gif")
        #expect(results.first?.media.width == 480)
        #expect(results.first?.media.height == 270)
    }

    @Test func extractsGiphyIDAndBuildsPrivacyPreservingLookupForLegacyMP4Messages() throws {
        let legacyURL = try #require(URL(
            string: "https://media2.giphy.com/media/v1.Y2lkPT/legacy-ID_1/giphy.mp4?cid=client&rid=giphy.mp4"
        ))

        let id = try #require(GiphySearchClient.giphyID(from: legacyURL))
        let request = try #require(GiphySearchClient.lookupRequest(id: id, apiKey: "test-key"))

        #expect(id == "legacy-ID_1")
        #expect(request.url?.host == "api.giphy.com")
        #expect(request.url?.path == "/v1/gifs/legacy-ID_1")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.value(forHTTPHeaderField: "Cache-Control") == "no-store")
        #expect(request.url?.query?.contains("api_key=test-key") == true)
    }

    @Test func legacyLookupSelectsAnExactAnimatedURLReturnedByGiphy() throws {
        let json = #"""
        {
          "data": {
            "id": "legacy",
            "title": "Legacy",
            "images": {
              "fixed_width": {
                "url": "https://media2.giphy.com/media/legacy/200w.gif?cid=client&rid=200w.gif",
                "width": "200", "height": "113", "size": "250000",
                "mp4": "https://media2.giphy.com/media/legacy/200w.mp4",
                "mp4_size": "100000"
              }
            }
          }
        }
        """#

        let media = try GiphySearchClient.decodeLookupResult(from: Data(json.utf8))

        #expect(media.url.absoluteString == "https://media2.giphy.com/media/legacy/200w.gif?cid=client&rid=200w.gif")
    }

    @Test func decoderPrefersTheLargestAnimatedRenditionUnderTheFastLoadBudget() throws {
        let json = #"""
        {
          "data": [{
            "id": "bounded",
            "title": "Bounded",
            "images": {
              "original": {
                "width": "960", "height": "540", "size": "3145728",
                "url": "https://media.giphy.com/media/bounded/original.gif"
              },
              "downsized": {
                "width": "800", "height": "450", "size": "1800000",
                "url": "https://media.giphy.com/media/bounded/downsized.gif"
              },
              "fixed_height": {
                "width": "640", "height": "360", "size": "800000",
                "url": "https://media.giphy.com/media/bounded/640.gif"
              },
              "fixed_width": {
                "width": "480", "height": "270", "size": "400000",
                "url": "https://media.giphy.com/media/bounded/480.gif"
              }
            }
          }]
        }
        """#

        let result = try #require(GiphySearchClient.decodeResults(from: Data(json.utf8)).first)

        #expect(result.media.url.absoluteString == "https://media.giphy.com/media/bounded/downsized.gif")
        #expect(result.media.width == 800)
        #expect(result.media.height == 450)
    }

    @MainActor
    @Test func automaticLoadingIsOffByDefaultAndPersistsExplicitChoice() throws {
        let suiteName = "GiphyIntegrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let initial = RemoteGIFLoadingStore(defaults: defaults)
        #expect(!initial.automaticallyLoads)

        initial.setAutomaticallyLoads(true)
        let restored = RemoteGIFLoadingStore(defaults: defaults)
        #expect(restored.automaticallyLoads)
    }

    @MainActor
    @Test func playbackBudgetBoundsConcurrentPlayersAndReopensAfterRelease() async throws {
        let budget = GiphyPlaybackBudget(maximumConcurrentPlaybacks: 2)
        let first = try #require(await budget.acquire())
        let second = try #require(await budget.acquire())

        #expect(budget.activePlaybackCount == 2)
        let waiting = Task { await budget.acquire() }
        await Task.yield()

        budget.release(first)
        let third = try #require(await waiting.value)
        #expect(budget.activePlaybackCount == 2)

        budget.release(first)
        #expect(budget.activePlaybackCount == 2)

        budget.release(second)
        budget.release(third)
        #expect(budget.activePlaybackCount == 0)
    }
}
