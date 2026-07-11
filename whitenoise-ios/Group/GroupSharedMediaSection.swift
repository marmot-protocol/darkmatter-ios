import SwiftUI
import MarmotKit

enum GroupSharedMediaCategory: String, CaseIterable, Identifiable {
    case media = "Media"
    case files = "Files"

    var id: String { rawValue }
}

nonisolated struct GroupSharedMediaItem: Identifiable, Equatable {
    let id: String
    let attachment: MessageMediaAttachment
    let timestamp: UInt64

    var isVisual: Bool {
        attachment.isImage || attachment.isVideo
    }
}

nonisolated enum GroupSharedMediaPresentation {
    static func items(from records: [MediaRecordFfi]) -> [GroupSharedMediaItem] {
        records.map { record in
            let stableRecordID = record.messageIdHex.isEmpty
                ? record.reference.plaintextSha256.lowercased()
                : record.messageIdHex
            let ownerID = "shared-media:\(stableRecordID):\(record.attachmentIndex)"
            let attachment = MessageMediaAttachment.displayItems(
                from: [record.reference],
                ownerId: ownerID
            )[0]
            return GroupSharedMediaItem(
                id: ownerID,
                attachment: attachment,
                timestamp: max(record.recordedAt, record.receivedAt)
            )
        }
        .sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.id > rhs.id
        }
    }

    static func visualItems(from items: [GroupSharedMediaItem]) -> [GroupSharedMediaItem] {
        items.filter(\.isVisual)
    }

    static func fileItems(from items: [GroupSharedMediaItem]) -> [GroupSharedMediaItem] {
        items.filter { !$0.isVisual }
    }
}

struct GroupSharedMediaSection: View {
    let records: [MediaRecordFfi]
    let isLoading: Bool
    let error: String?
    let onRetry: () -> Void
    let onLoadMedia: ConversationMediaLoader
    let onOpenGallery: (MessageMediaGallery) -> Void

    @State private var selectedCategory = GroupSharedMediaCategory.media
    @State private var loadingFileID: String?
    @State private var fileShare: GroupSharedMediaFileShare?
    @State private var fileOpenError: String?

    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 64), spacing: 3),
        count: 3
    )

    var body: some View {
        let items = GroupSharedMediaPresentation.items(from: records)

        Section {
            Picker("Shared media type", selection: $selectedCategory) {
                ForEach(GroupSharedMediaCategory.allCases) { category in
                    Text(category.rawValue).tag(category)
                }
            }
            .pickerStyle(.segmented)

            if isLoading && records.isEmpty {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 20)
            } else if let error, records.isEmpty {
                ContentUnavailableView {
                    Label("Shared media unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry", action: onRetry)
                }
            } else {
                switch selectedCategory {
                case .media:
                    mediaGrid(items: items)
                case .files:
                    filesList(items: items)
                }
            }
        } header: {
            Text("Shared Media")
        }
        .sheet(item: $fileShare) { share in
            ActivityShareSheet(items: [share.url])
        }
        .alert(
            "Couldn't open file",
            isPresented: Binding(
                get: { fileOpenError != nil },
                set: { if !$0 { fileOpenError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { fileOpenError = nil }
        } message: {
            Text(fileOpenError ?? "")
        }
    }

    @ViewBuilder
    private func mediaGrid(items: [GroupSharedMediaItem]) -> some View {
        let visualItems = GroupSharedMediaPresentation.visualItems(from: items)

        if visualItems.isEmpty {
            sharedMediaEmptyState(
                title: "No photos or videos",
                systemImage: "photo.on.rectangle.angled"
            )
        } else {
            LazyVGrid(columns: columns, spacing: 3) {
                ForEach(visualItems) { item in
                    GroupSharedMediaThumbnail(
                        item: item.attachment,
                        onLoadMedia: onLoadMedia
                    ) { initialData in
                        let attachments = visualItems.map(\.attachment)
                        guard let gallery = MessageMediaGallery(
                            items: attachments,
                            initialItem: item.attachment,
                            initialMediaData: initialData
                        ) else { return }
                        onOpenGallery(gallery)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    @ViewBuilder
    private func filesList(items: [GroupSharedMediaItem]) -> some View {
        let fileItems = GroupSharedMediaPresentation.fileItems(from: items)

        if fileItems.isEmpty {
            sharedMediaEmptyState(title: "No files", systemImage: "doc")
        } else {
            ForEach(fileItems) { item in
                Button {
                    Task { await openFile(item) }
                } label: {
                    HStack(spacing: 12) {
                        if loadingFileID == item.id {
                            ProgressView()
                                .frame(width: 30, height: 30)
                        } else {
                            Image(systemName: item.attachment.kind.systemImageName)
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .frame(width: 30, height: 30)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.attachment.fileName)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text(fileSubtitle(for: item))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(loadingFileID != nil)
            }
        }
    }

    private func sharedMediaEmptyState(title: LocalizedStringKey, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Spacer()
            Label(title, systemImage: systemImage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.vertical, 18)
            Spacer()
        }
    }

    private func fileSubtitle(for item: GroupSharedMediaItem) -> String {
        let mediaType = ContentSanitizer.singleLine(item.attachment.mediaType, maxLength: 100)
            ?? L10n.string("Attachment")
        guard item.timestamp > 0 else { return mediaType }
        let date = Date(timeIntervalSince1970: TimeInterval(item.timestamp))
        return L10n.formatted(
            "%@ · %@",
            arguments: [mediaType, RelativeTime.short(date)],
            locale: AppLanguage.currentLocale
        )
    }

    @MainActor
    private func openFile(_ item: GroupSharedMediaItem) async {
        guard loadingFileID == nil else { return }
        loadingFileID = item.id
        defer { loadingFileID = nil }
        do {
            let data = try await onLoadMedia.data(for: item.attachment)
            guard !Task.isCancelled,
                  let url = await MediaPlaybackFileStore.fileURL(
                    for: item.attachment,
                    data: data
                  )
            else { return }
            fileShare = GroupSharedMediaFileShare(url: url)
        } catch is CancellationError {
            return
        } catch {
            fileOpenError = error.localizedDescription
        }
    }
}

private struct GroupSharedMediaFileShare: Identifiable {
    let id = UUID()
    let url: URL
}

private struct GroupSharedMediaThumbnail: View {
    let item: MessageMediaAttachment
    let onLoadMedia: ConversationMediaLoader
    let onOpen: (Data?) -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var thumbnail: UIImage?
    @State private var sourceData: Data?
    @State private var isLoading = false
    @State private var didFail = false

    private let pointSize: CGFloat = 120

    var body: some View {
        Button {
            Task {
                if thumbnail == nil {
                    await load(force: didFail)
                }
                guard thumbnail != nil else { return }
                onOpen(item.isImage ? sourceData : nil)
            }
        } label: {
            GeometryReader { geometry in
                ZStack {
                    Color(.tertiarySystemFill)
                    if let thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                            .frame(
                                width: geometry.size.width,
                                height: geometry.size.height
                            )
                            .clipped()
                    } else if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: didFail ? "arrow.clockwise" : item.kind.systemImageName)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }

                    if item.isVideo, thumbnail != nil {
                        Image(systemName: "play.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .background(Color.black.opacity(0.55), in: Circle())
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
            }
            .aspectRatio(1, contentMode: .fit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.fileName)
        .task(id: item.id) {
            await load()
        }
    }

    @MainActor
    private func load(force: Bool = false) async {
        guard !isLoading else { return }
        let maxPixelSize = max(1, Int(ceil(pointSize * displayScale)))
        let cacheKey = MessageMediaThumbnailPresentation.cacheKey(for: item)

        if !force, item.isImage,
           let cached = MessageMediaThumbnailDecoder.cachedThumbnail(
            for: cacheKey,
            maxPixelSize: maxPixelSize
           )
        {
            thumbnail = cached.image
            sourceData = cached.sourceData
            didFail = false
            return
        }
        if !force, item.isVideo,
           let cached = MessageVideoThumbnailDecoder.cachedThumbnail(
            for: cacheKey,
            maxPixelSize: maxPixelSize
           )
        {
            thumbnail = cached
            didFail = false
            return
        }

        isLoading = true
        didFail = false
        defer { isLoading = false }
        do {
            let data = try await onLoadMedia.data(for: item)
            guard !Task.isCancelled else { return }
            if item.isImage {
                guard let decoded = await MessageMediaThumbnailDecoder.image(
                    data: data,
                    maxPixelSize: maxPixelSize,
                    scale: displayScale
                ) else {
                    didFail = true
                    return
                }
                MessageMediaThumbnailDecoder.store(
                    decoded,
                    sourceData: data,
                    for: cacheKey,
                    maxPixelSize: maxPixelSize
                )
                sourceData = data
                thumbnail = decoded
            } else if item.isVideo,
                      let url = await MediaPlaybackFileStore.fileURL(for: item, data: data),
                      let decoded = await MessageVideoThumbnailDecoder.thumbnail(
                        url: url,
                        maxPixelSize: maxPixelSize,
                        scale: displayScale
                      )
            {
                MessageVideoThumbnailDecoder.store(
                    decoded,
                    for: cacheKey,
                    maxPixelSize: maxPixelSize
                )
                thumbnail = decoded
            } else {
                didFail = true
            }
        } catch is CancellationError {
            return
        } catch {
            didFail = true
        }
    }
}
