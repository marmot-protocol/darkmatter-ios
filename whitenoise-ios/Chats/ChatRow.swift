import SwiftUI
import MarmotKit
import UIKit

/// One row in the chats list. Renders 2-member groups in "DM" style (other
/// member's identity in place of group name) and N>2 groups by group name.
/// The subtitle previews the latest message; the trailing label is its
/// relative timestamp.
struct ChatRow: View {
    @Environment(AppState.self) private var appState
    let item: ChatsListViewModel.Item

    var body: some View {
        HStack(spacing: 12) {
            GroupAvatarBubble(
                groupIdHex: item.id,
                imageHashHex: encryptedImageHashHex,
                seed: item.avatarSeed,
                title: title,
                pictureURL: avatarURLForDisplay
            )
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(item.hasUnread ? .headline.weight(.semibold) : .headline)
                        .lineLimit(1)
                    if item.isMuted {
                        Image(systemName: MuteBadgePresentation.systemImageName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(Text(L10n.string("Muted")))
                    }
                }
                Text(subtitle)
                    .font(.subheadline)
                    .fontWeight(item.draftPreview != nil || item.hasUnread ? .semibold : .regular)
                    .foregroundStyle(
                        item.draftPreview != nil
                            ? Color.accentColor
                            : (item.hasUnread ? .primary : .secondary)
                    )
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                if let timestamp {
                    Text(timestamp)
                        .font(.caption)
                        .foregroundStyle(item.hasUnread ? Color.accentColor : .secondary)
                        .fontWeight(item.hasUnread ? .semibold : .regular)
                        .monospacedDigit()
                }
                if item.hasUnread || item.hasUnreadMention {
                    HStack(spacing: 4) {
                        if item.hasUnreadMention {
                            MentionBadge()
                        }
                        if item.hasUnread {
                            UnreadCountBadge(count: item.unreadCount)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        item.title
    }

    private var encryptedImageHashHex: String? {
        item.row.pendingConfirmation ? nil : item.row.avatar?.imageHashHex
    }

    private var avatarURLForDisplay: URL? {
        if encryptedImageHashHex != nil, ContentSanitizer.imageURL(item.row.avatarUrl) == nil {
            return nil
        }
        return Self.automaticAvatarURL(
            item.avatarURL,
            pendingConfirmation: item.row.pendingConfirmation
        )
    }

    /// Latest message preview. Sent messages are prefixed with "You:".
    private var subtitle: String {
        Self.subtitleText(for: item, activeAccountIdHex: appState.activeAccount?.accountIdHex)
    }

    static func subtitleText(
        for item: ChatsListViewModel.Item,
        activeAccountIdHex: String?
    ) -> String {
        if let draftPreview = item.draftPreview {
            return L10n.formatted("Draft: %@", draftPreview)
        }
        guard let latest = item.lastMessage else {
            return L10n.string("No messages yet")
        }
        let body = item.previewText ?? ""
        if latest.sender == activeAccountIdHex {
            return body.isEmpty ? L10n.string("You sent a message") : L10n.formatted("You: %@", body)
        }
        return body.isEmpty ? L10n.string("New message") : body
    }

    static func automaticAvatarURL(_ url: URL?, pendingConfirmation: Bool) -> URL? {
        pendingConfirmation ? nil : url
    }

    private var timestamp: String? {
        guard let latest = item.lastMessage else { return nil }
        return RelativeTime.short(Date(timeIntervalSince1970: TimeInterval(latest.timelineAt)))
    }

}

struct MentionBadge: View {
    var body: some View {
        Image(systemName: MentionBadgePresentation.systemImageName)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Color.orange))
            .accessibilityLabel(Text(verbatim: "Unread mention"))
    }
}

nonisolated enum MentionBadgePresentation {
    static let systemImageName = "at"
}

nonisolated enum MuteBadgePresentation {
    static let systemImageName = "bell.slash.fill"
}

/// Circular avatar. Renders the profile picture when a URL is provided,
/// otherwise falls back to initials over a deterministic color derived from
/// the seed string (so a given group/person keeps the same color).
struct AvatarBubble: View {
    let seed: String
    let title: String
    var pictureURL: URL? = nil
    var pictureImage: UIImage? = nil

    var body: some View {
        Circle()
            .fill(LinearGradient(
                colors: [color.opacity(0.85), color.opacity(0.5)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
            .overlay {
                initialsView
                if let pictureURL {
                    AvatarRemoteImage(url: pictureURL)
                } else if let pictureImage {
                    Image(uiImage: pictureImage)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(Circle())
    }

    private var initialsView: some View {
        Text(initials)
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var initials: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "?" }
        let parts = trimmed.split(separator: " ", maxSplits: 1)
        let first = parts.first?.first.map(String.init) ?? ""
        let second = parts.count > 1 ? (parts[1].first.map(String.init) ?? "") : ""
        let combined = (first + second).uppercased()
        return combined.isEmpty ? "?" : combined
    }

    private var color: Color {
        let palette: [Color] = [.indigo, .blue, .teal, .green, .orange, .pink, .purple, .red]
        let hash = seed.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return palette[Self.paletteIndex(forHash: hash, paletteCount: palette.count)]
    }

    static func paletteIndex(forHash hash: Int, paletteCount: Int) -> Int {
        precondition(paletteCount > 0)
        return Int(hash.magnitude % UInt(paletteCount))
    }
}

/// Group avatar renderer. URL components retain precedence for backwards
/// compatibility; otherwise the content-addressed encrypted Blossom image is
/// fetched and decrypted through Marmot.
struct GroupAvatarBubble: View {
    @Environment(AppState.self) private var appState
    @Environment(\.displayScale) private var displayScale

    let groupIdHex: String
    let imageHashHex: String?
    let seed: String
    let title: String
    var pictureURL: URL? = nil

    @State private var phase = Phase.idle

    var body: some View {
        GeometryReader { proxy in
            let request = request(
                size: proxy.size,
                scale: displayScale,
                accountRef: appState.activeAccountRef
            )
            AvatarBubble(
                seed: seed,
                title: title,
                pictureURL: pictureURL,
                pictureImage: image(for: request)
            )
            .task(id: request) {
                await load(request)
            }
        }
    }

    private func request(
        size: CGSize,
        scale: CGFloat,
        accountRef: String?
    ) -> GroupAvatarImageRequest? {
        guard pictureURL == nil,
              let accountRef,
              let imageHashHex,
              !imageHashHex.isEmpty
        else { return nil }
        return GroupAvatarImageRequest(
            accountRef: accountRef,
            groupIdHex: groupIdHex,
            imageHashHex: imageHashHex,
            maxPixelSize: Int(ceil(max(size.width, size.height, 1) * max(scale, 1)))
        )
    }

    private func image(for request: GroupAvatarImageRequest?) -> UIImage? {
        guard case .success(let loadedRequest, let image) = phase,
              loadedRequest == request
        else { return nil }
        return image
    }

    private func load(_ request: GroupAvatarImageRequest?) async {
        guard let request else {
            phase = .idle
            return
        }
        phase = .loading(request)
        do {
            let client = try appState.currentMarmotClient()
            let image = try await GroupAvatarImageLoader.image(
                request: request,
                scale: displayScale,
                client: client
            )
            guard !Task.isCancelled else { return }
            phase = .success(request, image)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failure(request)
        }
    }

    private enum Phase {
        case idle
        case loading(GroupAvatarImageRequest)
        case success(GroupAvatarImageRequest, UIImage)
        case failure(GroupAvatarImageRequest)
    }
}

private struct GroupAvatarImageRequest: Hashable {
    let accountRef: String
    let groupIdHex: String
    let imageHashHex: String
    let maxPixelSize: Int
}

private actor GroupAvatarLoadLimiter {
    static let shared = GroupAvatarLoadLimiter(maximumConcurrentLoads: 4)

    private let maximumConcurrentLoads: Int
    private var activeLoads = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maximumConcurrentLoads: Int) {
        self.maximumConcurrentLoads = max(1, maximumConcurrentLoads)
    }

    func acquire() async {
        if activeLoads < maximumConcurrentLoads {
            activeLoads += 1
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    func release() {
        if waiters.isEmpty {
            activeLoads = max(0, activeLoads - 1)
        } else {
            waiters.removeFirst().resume()
        }
    }
}

@MainActor
private enum GroupAvatarImageLoader {
    private final class CachedImage: NSObject {
        let image: UIImage

        init(_ image: UIImage) {
            self.image = image
        }
    }

    private static let cache: NSCache<NSString, CachedImage> = {
        let cache = NSCache<NSString, CachedImage>()
        cache.totalCostLimit = 20 * 1024 * 1024
        return cache
    }()

    private static let dataCache: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 16 * 1024 * 1024
        return cache
    }()

    private static var inFlight: [String: Task<Data, Error>] = [:]

    static func image(
        request: GroupAvatarImageRequest,
        scale: CGFloat,
        client: MarmotClient
    ) async throws -> UIImage {
        let cacheKey = "\(request.accountRef):\(request.imageHashHex):\(request.maxPixelSize)" as NSString
        if let cached = cache.object(forKey: cacheKey)?.image {
            return cached
        }

        let dataKey = "\(request.accountRef):\(request.groupIdHex):\(request.imageHashHex)"
        let data: Data
        if let cached = dataCache.object(forKey: dataKey as NSString) {
            data = cached as Data
        } else if let task = inFlight[dataKey] {
            data = try await task.value
        } else {
            let task = Task {
                await GroupAvatarLoadLimiter.shared.acquire()
                do {
                    try Task.checkCancellation()
                    let data = try await client.downloadGroupBlossomImage(
                        accountRef: request.accountRef,
                        groupIdHex: request.groupIdHex
                    )
                    await GroupAvatarLoadLimiter.shared.release()
                    return data
                } catch {
                    await GroupAvatarLoadLimiter.shared.release()
                    throw error
                }
            }
            inFlight[dataKey] = task
            defer { inFlight[dataKey] = nil }
            data = try await task.value
            dataCache.setObject(
                data as NSData,
                forKey: dataKey as NSString,
                cost: data.count
            )
        }

        guard let image = await RemoteImageDecoder.downsampledImage(
            from: data,
            maxPixelSize: request.maxPixelSize,
            scale: scale
        ) else {
            throw URLError(.cannotDecodeContentData)
        }
        cache.setObject(
            CachedImage(image),
            forKey: cacheKey,
            cost: DecodedImageCost.decodedBitmapByteCost(for: image)
        )
        return image
    }
}

private struct AvatarRemoteImage: View {
    let url: URL

    @Environment(\.displayScale) private var displayScale
    @State private var phase = Phase.loading

    var body: some View {
        GeometryReader { proxy in
            let request = AvatarRemoteImageRequest(
                url: url,
                maxPixelSize: maxPixelSize(for: proxy.size, scale: displayScale)
            )

            content(for: request)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: request) {
                    await load(request)
                }
        }
    }

    @ViewBuilder
    private func content(for request: AvatarRemoteImageRequest) -> some View {
        switch phase {
        case .success(let loadedRequest, let image) where loadedRequest == request:
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        case .loading, .failure, .success:
            Color.clear
        }
    }

    private func load(_ request: AvatarRemoteImageRequest) async {
        phase = .loading
        do {
            let image = try await RemoteAvatarImageLoader.image(
                for: request.url,
                maxPixelSize: request.maxPixelSize,
                scale: displayScale
            )
            guard !Task.isCancelled else { return }
            phase = .success(request, image)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failure(request)
        }
    }

    private func maxPixelSize(for size: CGSize, scale: CGFloat) -> Int {
        Int(ceil(max(size.width, size.height, 1) * max(scale, 1)))
    }

    private enum Phase {
        case loading
        case success(AvatarRemoteImageRequest, UIImage)
        case failure(AvatarRemoteImageRequest)
    }
}

private struct AvatarRemoteImageRequest: Hashable {
    let url: URL
    let maxPixelSize: Int
}
