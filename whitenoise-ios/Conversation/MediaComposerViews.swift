import SwiftUI
import UIKit
import AVKit
import PhotosUI
import UniformTypeIdentifiers

nonisolated enum ComposerMediaDraftPresentation {
    static func inlineAudioDraft(in attachments: [MediaDraftAttachment]) -> MediaDraftAttachment? {
        let audioDrafts = attachments.filter { $0.kind == .audio }
        return audioDrafts.count == 1 ? audioDrafts[0] : nil
    }

    static func stripAttachments(from attachments: [MediaDraftAttachment]) -> [MediaDraftAttachment] {
        guard let inlineAudio = inlineAudioDraft(in: attachments) else {
            return attachments
        }
        return attachments.filter { $0.id != inlineAudio.id }
    }
}

nonisolated enum ComposerMediaDraftLayout {
    static let previewHeight: CGFloat = 112
    static let minimumPreviewWidth: CGFloat = 68
    static let maximumPreviewWidth: CGFloat = 200
    static let cornerRadius: CGFloat = 14
    static let shelfPadding: CGFloat = 8
    static let itemSpacing: CGFloat = 8
    static let utilityPreviewHeight: CGFloat = 72
    static let minimumUtilityPreviewWidth: CGFloat = 104
    static let maximumUtilityPreviewWidth: CGFloat = 160

    static func previewWidth(dim: String?, thumbnailSize: CGSize?) -> CGFloat {
        let ratio = aspectRatio(dim: dim) ?? thumbnailSize.flatMap { size in
            guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
                return nil
            }
            return size.width / size.height
        } ?? 1
        return min(maximumPreviewWidth, max(minimumPreviewWidth, previewHeight * ratio))
            .rounded(.toNearestOrAwayFromZero)
    }

    static func aspectRatio(dim: String?) -> CGFloat? {
        guard let dim else { return nil }
        let parts = dim.lowercased().split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]),
              width.isFinite,
              height.isFinite,
              width > 0,
              height > 0
        else { return nil }
        let ratio = CGFloat(width / height)
        return ratio.isFinite && ratio > 0 ? ratio : nil
    }
}

nonisolated enum VideoPreviewOverlayPresentation {
    static let compactDiameter: CGFloat = 44
    static let regularDiameter: CGFloat = 64
    static let maximumDiameter: CGFloat = 76

    static func diameter(for size: CGSize) -> CGFloat {
        let shortestSide = min(size.width, size.height)
        guard shortestSide.isFinite, shortestSide >= 96 else {
            return compactDiameter
        }
        return min(maximumDiameter, max(regularDiameter, shortestSide * 0.24))
            .rounded(.toNearestOrAwayFromZero)
    }

    static func iconFontSize(for diameter: CGFloat) -> CGFloat {
        max(19, diameter * 0.42).rounded(.toNearestOrAwayFromZero)
    }
}

struct VideoPreviewPlayOverlay: View {
    var systemName = "play.fill"
    let diameter: CGFloat

    var body: some View {
        Image(systemName: systemName)
            .font(.system(
                size: VideoPreviewOverlayPresentation.iconFontSize(for: diameter),
                weight: .bold
            ))
            .foregroundStyle(.white)
            .frame(width: diameter, height: diameter)
            .background(Color.black.opacity(0.5), in: Circle())
            .shadow(color: Color.black.opacity(0.28), radius: 8, y: 2)
    }
}

struct MediaDraftStrip: View {
    let attachments: [MediaDraftAttachment]
    let onRemove: (MediaDraftAttachment.ID) -> Void
    let onPreviewVisual: (MediaDraftAttachment.ID) -> Void

    private var containsVisualMedia: Bool {
        attachments.contains { $0.kind == .image || $0.kind == .video }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: ComposerMediaDraftLayout.itemSpacing) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        preview(for: attachment)

                        ComposerAttachmentRemoveButton(
                            accessibilityLabel: "Remove \(attachment.fileName)",
                            overlaysMedia: attachment.kind == .image || attachment.kind == .video
                        ) {
                            onRemove(attachment.id)
                        }
                    }
                }
            }
            .padding(ComposerMediaDraftLayout.shelfPadding)
        }
        .frame(height: containsVisualMedia
            ? ComposerMediaDraftLayout.previewHeight + (ComposerMediaDraftLayout.shelfPadding * 2)
            : ComposerMediaDraftLayout.utilityPreviewHeight + (ComposerMediaDraftLayout.shelfPadding * 2))
        .clipShape(.rect(topLeadingRadius: 22, topTrailingRadius: 22))
        .overlay(alignment: .bottom) {
            if containsVisualMedia {
                Divider()
                    .padding(.horizontal, 12)
            }
        }
    }

    @ViewBuilder
    private func preview(for attachment: MediaDraftAttachment) -> some View {
        switch attachment.kind {
        case .image, .video:
            Button {
                onPreviewVisual(attachment.id)
            } label: {
                let width = ComposerMediaDraftLayout.previewWidth(
                    dim: attachment.dim,
                    thumbnailSize: attachment.thumbnail?.size
                )
                ZStack {
                    thumbnail(for: attachment)
                    if attachment.kind == .video {
                        VideoPreviewPlayOverlay(
                            diameter: VideoPreviewOverlayPresentation.diameter(
                                for: CGSize(width: width, height: ComposerMediaDraftLayout.previewHeight)
                            )
                        )
                    }
                }
                .frame(width: width, height: ComposerMediaDraftLayout.previewHeight)
                .clipShape(.rect(cornerRadius: ComposerMediaDraftLayout.cornerRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: ComposerMediaDraftLayout.cornerRadius)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview \(attachment.fileName)")
        case .audio:
            HStack(spacing: 8) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                AudioWaveformView(
                    samples: attachment.waveformSamples,
                    progress: 0,
                    barColor: Color.accentColor.opacity(0.88),
                    playedColor: Color.accentColor
                )
                .frame(width: 82, height: 34)
            }
            .padding(.horizontal, 10)
            .frame(
                minWidth: ComposerMediaDraftLayout.minimumUtilityPreviewWidth,
                maxWidth: ComposerMediaDraftLayout.maximumUtilityPreviewWidth,
                minHeight: ComposerMediaDraftLayout.utilityPreviewHeight,
                maxHeight: ComposerMediaDraftLayout.utilityPreviewHeight
            )
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
        case .document, .unsupported:
            VStack(spacing: 5) {
                Image(systemName: attachment.kind.systemImageName)
                    .font(.system(size: 18, weight: .semibold))
                Text(attachment.fileName)
                    .font(.caption2)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.secondary)
            .padding(8)
            .frame(
                minWidth: ComposerMediaDraftLayout.minimumUtilityPreviewWidth,
                maxWidth: ComposerMediaDraftLayout.maximumUtilityPreviewWidth,
                minHeight: ComposerMediaDraftLayout.utilityPreviewHeight,
                maxHeight: ComposerMediaDraftLayout.utilityPreviewHeight
            )
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
        }
    }

    @ViewBuilder
    private func thumbnail(for attachment: MediaDraftAttachment) -> some View {
        if let thumbnail = attachment.thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                Color(.secondarySystemBackground)
                Image(systemName: attachment.kind.systemImageName)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ComposerAttachmentRemoveButton: View {
    let accessibilityLabel: String
    let overlaysMedia: Bool
    let action: () -> Void

    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(fill)
                Circle()
                    .stroke(stroke, lineWidth: 0.5)
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(glyph)
            }
            .frame(width: 20, height: 20)
            .shadow(color: overlaysMedia ? .black.opacity(0.16) : .clear, radius: 1, y: 0.5)
            .padding([.top, .trailing], 6)
            .frame(width: 44, height: 44, alignment: .topTrailing)
            .contentShape(.rect)
        }
        .buttonStyle(ComposerAttachmentRemoveButtonStyle())
        .accessibilityLabel(accessibilityLabel)
    }

    private var fill: Color {
        overlaysMedia
            ? .black.opacity(colorSchemeContrast == .increased ? 0.74 : 0.58)
            : .secondary.opacity(0.22)
    }

    private var stroke: Color {
        overlaysMedia
            ? .white.opacity(colorSchemeContrast == .increased ? 0.52 : 0.32)
            : .primary.opacity(0.08)
    }

    private var glyph: Color {
        overlaysMedia ? .white.opacity(0.96) : .primary.opacity(0.72)
    }
}

private struct ComposerAttachmentRemoveButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .animation(.smooth(duration: 0.12), value: configuration.isPressed)
    }
}

nonisolated struct ComposerMediaSelection: Identifiable {
    let attachments: [MediaDraftAttachment]
    let initialItemID: MediaDraftAttachment.ID

    init?(attachments: [MediaDraftAttachment], initialItemID: MediaDraftAttachment.ID) {
        let visualAttachments = attachments.filter { $0.kind == .image || $0.kind == .video }
        guard visualAttachments.contains(where: { $0.id == initialItemID }) else { return nil }
        self.attachments = visualAttachments
        self.initialItemID = initialItemID
    }

    var id: MediaDraftAttachment.ID { initialItemID }

    func applying(
        includedItemIDs: Set<MediaDraftAttachment.ID>,
        to allAttachments: [MediaDraftAttachment]
    ) -> [MediaDraftAttachment] {
        let reviewedItemIDs = Set(attachments.map(\.id))
        return allAttachments.filter { attachment in
            !reviewedItemIDs.contains(attachment.id) || includedItemIDs.contains(attachment.id)
        }
    }
}

struct ComposerMediaPreviewView: View {
    let selection: ComposerMediaSelection
    let onConfirm: (Set<MediaDraftAttachment.ID>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedItemID: MediaDraftAttachment.ID
    @State private var includedItemIDs: Set<MediaDraftAttachment.ID>

    private enum Layout {
        static let thumbnailHeight: CGFloat = 44
        static let thumbnailMinimumWidth: CGFloat = 32
        static let thumbnailMaximumWidth: CGFloat = 72
        static let thumbnailCornerRadius: CGFloat = 7
        static let thumbnailSpacing: CGFloat = 6
        static let thumbnailHorizontalMargin: CGFloat = 32
        static let thumbnailVerticalPadding: CGFloat = 14
        static let selectedThumbnailScale: CGFloat = 1.08
        static let inclusionControlSize: CGFloat = 22
        static let inclusionControlHitSize: CGFloat = 44

        static var navigatorHeight: CGFloat {
            thumbnailHeight * selectedThumbnailScale + thumbnailVerticalPadding * 2
        }
    }

    init(
        selection: ComposerMediaSelection,
        onConfirm: @escaping (Set<MediaDraftAttachment.ID>) -> Void
    ) {
        self.selection = selection
        self.onConfirm = onConfirm
        _selectedItemID = State(initialValue: selection.initialItemID)
        _includedItemIDs = State(initialValue: Set(selection.attachments.map(\.id)))
    }

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                VStack(spacing: 0) {
                    mediaPager
                        .frame(
                            width: proxy.size.width,
                            height: max(1, proxy.size.height - thumbnailNavigatorHeight)
                        )

                    if selection.attachments.count > 1 {
                        thumbnailNavigator
                            .frame(height: Layout.navigatorHeight)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Label(L10n.string("Cancel"), systemImage: "xmark")
                            .labelStyle(.iconOnly)
                    }
                    .accessibilityLabel(L10n.string("Cancel"))
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        onConfirm(includedItemIDs)
                        dismiss()
                    } label: {
                        Label(L10n.string("Apply"), systemImage: "checkmark")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityLabel(L10n.string("Apply"))
                }
            }
            .navigationTitle(L10n.string("Preview"))
            .navigationBarTitleDisplayMode(.inline)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private var thumbnailNavigatorHeight: CGFloat {
        selection.attachments.count > 1 ? Layout.navigatorHeight : 0
    }

    private var mediaPager: some View {
        TabView(selection: $selectedItemID) {
            ForEach(Array(selection.attachments.enumerated()), id: \.element.id) { index, attachment in
                GeometryReader { proxy in
                    let mediaSize = fittedMediaSize(for: attachment, in: proxy.size)
                    ZStack(alignment: .bottomTrailing) {
                        ComposerMediaPreviewPage(
                            attachment: attachment,
                            isSelected: attachment.id == selectedItemID
                        )
                        .frame(width: mediaSize.width, height: mediaSize.height)

                        inclusionButton(for: attachment)
                    }
                    .frame(width: mediaSize.width, height: mediaSize.height)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(
                        L10n.formatted(
                            "%@, %@ of %@",
                            arguments: [
                                attachment.fileName,
                                LocalizedNumberLabel.decimal(UInt64(index + 1)),
                                LocalizedNumberLabel.decimal(UInt64(selection.attachments.count)),
                            ],
                            locale: AppLanguage.currentLocale
                        )
                    )
                }
                .tag(attachment.id)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private func inclusionButton(for attachment: MediaDraftAttachment) -> some View {
        let isIncluded = includedItemIDs.contains(attachment.id)
        return Button {
            withAnimation(.snappy) {
                if isIncluded {
                    includedItemIDs.remove(attachment.id)
                } else {
                    includedItemIDs.insert(attachment.id)
                }
            }
        } label: {
            ZStack {
                Circle()
                    .fill(isIncluded ? Color.accentColor : Color.black.opacity(0.36))
                Circle()
                    .stroke(.white, lineWidth: 1.5)
                if isIncluded {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: Layout.inclusionControlSize, height: Layout.inclusionControlSize)
            .shadow(color: .black.opacity(0.22), radius: 1.5, y: 0.5)
            .frame(width: Layout.inclusionControlHitSize, height: Layout.inclusionControlHitSize)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(attachment.fileName) in message")
        .accessibilityValue(isIncluded ? L10n.string("Included") : L10n.string("Not included"))
    }

    private var thumbnailNavigator: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Layout.thumbnailSpacing) {
                    ForEach(selection.attachments) { attachment in
                        Button {
                            withAnimation(.snappy) {
                                selectedItemID = attachment.id
                            }
                        } label: {
                            MediaApprovalThumbnail(attachment: attachment)
                                .frame(width: thumbnailWidth(for: attachment), height: Layout.thumbnailHeight)
                                .clipShape(.rect(cornerRadius: Layout.thumbnailCornerRadius))
                                .overlay {
                                    RoundedRectangle(cornerRadius: Layout.thumbnailCornerRadius)
                                        .strokeBorder(
                                            attachment.id == selectedItemID ? Color.accentColor : .clear,
                                            lineWidth: 2
                                        )
                                }
                                .opacity(includedItemIDs.contains(attachment.id) ? 1 : 0.42)
                                .scaleEffect(attachment.id == selectedItemID ? Layout.selectedThumbnailScale : 1)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Show \(attachment.fileName)")
                        .id(attachment.id)
                    }
                }
                .padding(.horizontal, Layout.thumbnailHorizontalMargin)
                .padding(.vertical, Layout.thumbnailVerticalPadding)
            }
            .onChange(of: selectedItemID) { _, itemID in
                withAnimation(.snappy) {
                    proxy.scrollTo(itemID, anchor: .center)
                }
            }
            .task {
                await Task.yield()
                proxy.scrollTo(selectedItemID, anchor: .center)
            }
        }
        .background(Color(.systemBackground))
    }

    private func thumbnailWidth(for attachment: MediaDraftAttachment) -> CGFloat {
        let ratio = ComposerMediaDraftLayout.aspectRatio(dim: attachment.dim)
            ?? attachment.thumbnail.map { $0.size.width / max(1, $0.size.height) }
            ?? 1
        return min(
            Layout.thumbnailMaximumWidth,
            max(Layout.thumbnailMinimumWidth, Layout.thumbnailHeight * ratio)
        )
    }

    private func fittedMediaSize(for attachment: MediaDraftAttachment, in availableSize: CGSize) -> CGSize {
        let availableWidth = max(1, availableSize.width)
        let availableHeight = max(1, availableSize.height)
        let ratio = ComposerMediaDraftLayout.aspectRatio(dim: attachment.dim)
            ?? attachment.thumbnail.map { $0.size.width / max(1, $0.size.height) }
            ?? 1
        let availableRatio = availableWidth / availableHeight
        if availableRatio > ratio {
            return CGSize(width: availableHeight * ratio, height: availableHeight)
        }
        return CGSize(width: availableWidth, height: availableWidth / ratio)
    }
}

private struct ComposerMediaPreviewPage: View {
    let attachment: MediaDraftAttachment
    let isSelected: Bool

    @State private var image: UIImage?
    @State private var player: AVPlayer?

    var body: some View {
        ZStack {
            Color.black
            if attachment.kind == .video {
                if let player {
                    VideoPlayer(player: player)
                } else if let thumbnail = attachment.thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                } else {
                    ProgressView().tint(.white)
                }
            } else if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else if let thumbnail = attachment.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: attachment.id) {
            await prepareMedia()
        }
        .onChange(of: isSelected) { _, selected in
            if selected {
                player?.play()
            } else {
                player?.pause()
            }
        }
        .onDisappear {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            player = nil
        }
    }

    private func prepareMedia() async {
        if attachment.kind == .image {
            let longestEdge = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
            image = await MessageMediaFullscreenPresentation.decodedImage(
                from: attachment.data,
                maxPixelSize: MessageMediaFullscreenPresentation.fullscreenMaxPixelSize(
                    forLongestScreenEdge: longestEdge
                ),
                scale: UIScreen.main.scale
            )
            return
        }
        guard attachment.kind == .video else { return }
        let producerEpoch = MessageMediaCache.currentProducerEpoch()
        guard let url = await MediaPlaybackFileStore.fileURL(
            for: attachment.displayItem,
            data: attachment.data,
            producerEpoch: producerEpoch
        ), !Task.isCancelled else { return }
        let next = AVPlayer(url: url)
        player = next
        if isSelected {
            next.play()
        }
    }
}

struct MediaApprovalView: View {
    @Binding var attachments: [MediaDraftAttachment]
    @Binding var caption: String
    let reservedAttachmentCount: Int
    let isSending: Bool
    let onAddSelections: ([PhotoLibrarySelection]) -> Void
    let onSelectionError: (Error) -> Void
    let onCancel: () -> Void
    let onSend: () -> Void

    @State private var selectedID: MediaDraftAttachment.ID?
    @State private var showPhotoLibraryPicker = false

    init(
        attachments: Binding<[MediaDraftAttachment]>,
        caption: Binding<String>,
        reservedAttachmentCount: Int,
        isSending: Bool,
        onAddSelections: @escaping ([PhotoLibrarySelection]) -> Void,
        onSelectionError: @escaping (Error) -> Void,
        onCancel: @escaping () -> Void,
        onSend: @escaping () -> Void
    ) {
        _attachments = attachments
        _caption = caption
        self.reservedAttachmentCount = reservedAttachmentCount
        self.isSending = isSending
        self.onAddSelections = onAddSelections
        self.onSelectionError = onSelectionError
        self.onCancel = onCancel
        self.onSend = onSend
        _selectedID = State(initialValue: attachments.wrappedValue.first?.id)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                TabView(selection: $selectedID) {
                    ForEach(attachments) { attachment in
                        MediaApprovalPage(attachment: attachment)
                            .tag(Optional(attachment.id))
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                approvalControls
            }
            .toolbarBackground(.black.opacity(0.92), for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.string("Cancel"), action: onCancel)
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .principal) {
                    Text(selectionCountLabel)
                        .font(.headline)
                        .foregroundStyle(.white)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive, action: removeSelectedAttachment) {
                        Image(systemName: "trash")
                            .foregroundStyle(.white)
                    }
                    .disabled(selectedID == nil)
                    .accessibilityLabel(L10n.string("Remove attachment"))
                }
            }
        }
        .sheet(isPresented: $showPhotoLibraryPicker) {
            PhotoLibraryPickerView(
                selectionLimit: remainingSelectionLimit,
                onSelection: onAddSelections,
                onError: onSelectionError,
                onDismiss: { showPhotoLibraryPicker = false }
            )
            .ignoresSafeArea()
        }
        .onChange(of: attachments.map(\.id)) { _, ids in
            if let selectedID, ids.contains(selectedID) { return }
            self.selectedID = ids.first
            if ids.isEmpty {
                onCancel()
            }
        }
    }

    private var approvalControls: some View {
        VStack(spacing: 12) {
            thumbnailRail

            HStack(alignment: .bottom, spacing: 10) {
                TextField(L10n.string("Add a caption…"), text: $caption, axis: .vertical)
                    .lineLimit(1 ... 4)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(Color.white.opacity(0.12), in: .rect(cornerRadius: 22))

                Button(action: onSend) {
                    Group {
                        if isSending {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "arrow.up")
                                .font(.body.weight(.bold))
                        }
                    }
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(attachments.isEmpty || isSending)
                .accessibilityLabel(L10n.string("Send"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .environment(\.colorScheme, .dark)
    }

    private var thumbnailRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                if remainingSelectionLimit > 0 {
                    Button {
                        showPhotoLibraryPicker = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 54, height: 54)
                            .background(Color.white.opacity(0.12), in: .rect(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.string("Add more"))
                }

                ForEach(attachments) { attachment in
                    Button {
                        selectedID = attachment.id
                    } label: {
                        MediaApprovalThumbnail(attachment: attachment)
                            .frame(width: 54, height: 54)
                            .clipShape(.rect(cornerRadius: 10))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10)
                                    .strokeBorder(
                                        attachment.id == selectedID ? Color.white : Color.white.opacity(0.16),
                                        lineWidth: attachment.id == selectedID ? 3 : 1
                                    )
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(attachment.fileName)
                    .accessibilityAddTraits(attachment.id == selectedID ? .isSelected : [])
                }
            }
            .padding(.horizontal, 1)
        }
    }

    private var remainingSelectionLimit: Int {
        max(0, MediaDraftProcessor.maxAttachmentCount - reservedAttachmentCount - attachments.count)
    }

    private var selectionCountLabel: String {
        let selectedIndex = attachments.firstIndex(where: { $0.id == selectedID }) ?? 0
        return L10n.formatted(
            "%@ of %@",
            arguments: [
                LocalizedNumberLabel.decimal(UInt64(selectedIndex + 1)),
                LocalizedNumberLabel.decimal(UInt64(attachments.count))
            ],
            locale: AppLanguage.currentLocale
        )
    }

    private func removeSelectedAttachment() {
        guard let selectedID,
              let selectedIndex = attachments.firstIndex(where: { $0.id == selectedID })
        else { return }
        attachments.remove(at: selectedIndex)
        guard !attachments.isEmpty else {
            self.selectedID = nil
            onCancel()
            return
        }
        self.selectedID = attachments[min(selectedIndex, attachments.count - 1)].id
    }
}

private struct MediaApprovalPage: View {
    let attachment: MediaDraftAttachment

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Color.black

            if attachment.kind == .image, let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let thumbnail = attachment.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: attachment.kind.systemImageName)
                    .font(.system(size: 48, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if attachment.kind == .video {
                VideoPreviewPlayOverlay(diameter: VideoPreviewOverlayPresentation.maximumDiameter)
            }
        }
        .task(id: attachment.id) {
            guard attachment.kind == .image else { return }
            let longestScreenEdge = max(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
            image = await MessageMediaFullscreenPresentation.decodedImage(
                from: attachment.data,
                maxPixelSize: MessageMediaFullscreenPresentation.fullscreenMaxPixelSize(
                    forLongestScreenEdge: longestScreenEdge
                ),
                scale: UIScreen.main.scale
            )
        }
    }
}

private struct MediaApprovalThumbnail: View {
    let attachment: MediaDraftAttachment

    var body: some View {
        ZStack {
            if let thumbnail = attachment.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(.secondarySystemBackground)
                Image(systemName: attachment.kind.systemImageName)
                    .foregroundStyle(.secondary)
            }

            if attachment.kind == .video {
                Image(systemName: "play.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(Color.black.opacity(0.52), in: Circle())
            }
        }
    }
}

struct CameraCaptureView: UIViewControllerRepresentable {
    let onImage: (UIImage) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onImage: onImage, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image"]
        picker.allowsEditing = false
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onImage: (UIImage) -> Void
        let onCancel: () -> Void

        init(onImage: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onImage = onImage
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                onImage(image)
            } else {
                onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}

struct PhotoLibrarySelection: Hashable {
    let data: Data
    let fileName: String?
    let typeIdentifier: String?

    init(data: Data, fileName: String?, typeIdentifier: String? = nil) {
        self.data = data
        self.fileName = fileName
        self.typeIdentifier = typeIdentifier
    }

    static func compactPreservingPickerOrder(_ selectionsByPickerIndex: [PhotoLibrarySelection?]) -> [PhotoLibrarySelection] {
        selectionsByPickerIndex.compactMap { $0 }
    }

    /// All accepted selections stay resident until the composer hands them
    /// off, so the per-item cap alone still allows count × cap in RAM. The
    /// session budget bounds the sum; selections beyond it are rejected the
    /// same way as oversized ones.
    static let maxTotalSelectionBytes = 3 * MediaDraftProcessor.maxAttachmentBytes

    /// Size gate applied before any bytes are read into memory; the same cap
    /// the draft processor enforces, moved ahead of materialization, plus the
    /// remaining session budget.
    static func admitsSelection(
        bytes: Int,
        cap: Int = MediaDraftProcessor.maxAttachmentBytes,
        remaining: Int = maxTotalSelectionBytes
    ) -> Bool {
        bytes > 0 && bytes <= cap && bytes <= remaining
    }
}

private enum PhotoLibraryPickerError: LocalizedError {
    case noReadableMedia

    var errorDescription: String? {
        switch self {
        case .noReadableMedia:
            return L10n.string("That attachment could not be opened.")
        }
    }
}

struct PhotoLibraryPickerView: UIViewControllerRepresentable {
    let selectionLimit: Int
    var filter: PHPickerFilter = .any(of: [.images, .videos])
    let onSelection: ([PhotoLibrarySelection]) -> Void
    let onError: (Error) -> Void
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelection: onSelection, onError: onError, onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = filter
        configuration.selectionLimit = max(1, selectionLimit)
        configuration.preferredAssetRepresentationMode = .current

        let picker = PHPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        private let onSelection: ([PhotoLibrarySelection]) -> Void
        private let onError: (Error) -> Void
        private let onDismiss: () -> Void

        init(
            onSelection: @escaping ([PhotoLibrarySelection]) -> Void,
            onError: @escaping (Error) -> Void,
            onDismiss: @escaping () -> Void
        ) {
            self.onSelection = onSelection
            self.onError = onError
            self.onDismiss = onDismiss
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            onDismiss()
            guard !results.isEmpty else { return }

            // Assets load one at a time through a file representation with a
            // size gate, and accepted bytes draw down a session budget — peak
            // memory is bounded by that budget, not by count × per-item cap.
            Task {
                var selectionsByPickerIndex = [PhotoLibrarySelection?](repeating: nil, count: results.count)
                var firstError: Error?
                var remainingBudget = PhotoLibrarySelection.maxTotalSelectionBytes

                for (index, result) in results.enumerated() {
                    let provider = result.itemProvider
                    guard let typeIdentifier = Self.mediaTypeIdentifier(from: provider) else { continue }
                    let fileName = Self.fileName(
                        suggestedName: provider.suggestedName,
                        typeIdentifier: typeIdentifier
                    )
                    do {
                        let selection = try await Self.loadBoundedSelection(
                            provider: provider,
                            typeIdentifier: typeIdentifier,
                            fileName: fileName,
                            remainingBudget: remainingBudget
                        )
                        remainingBudget -= selection.data.count
                        selectionsByPickerIndex[index] = selection
                    } catch {
                        if firstError == nil { firstError = error }
                    }
                }

                let selections = PhotoLibrarySelection.compactPreservingPickerOrder(selectionsByPickerIndex)
                await MainActor.run {
                    // A failure among successes (an oversized video next to a
                    // valid photo) surfaces alongside the delivered selections
                    // instead of silently dropping the item.
                    if let firstError, !selections.isEmpty {
                        self.onError(firstError)
                    }
                    if selections.isEmpty {
                        self.onError(firstError ?? PhotoLibraryPickerError.noReadableMedia)
                    } else {
                        self.onSelection(selections)
                    }
                }
            }
        }

        private static func loadBoundedSelection(
            provider: NSItemProvider,
            typeIdentifier: String,
            fileName: String?,
            remainingBudget: Int
        ) async throws -> PhotoLibrarySelection {
            try await withCheckedThrowingContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: typeIdentifier) { url, error in
                    // The provider deletes the temp file when this handler
                    // returns, so the size gate and the read both happen here.
                    guard let url else {
                        continuation.resume(throwing: error ?? PhotoLibraryPickerError.noReadableMedia)
                        return
                    }
                    guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                          size > 0
                    else {
                        continuation.resume(throwing: PhotoLibraryPickerError.noReadableMedia)
                        return
                    }
                    guard PhotoLibrarySelection.admitsSelection(bytes: size, remaining: remainingBudget) else {
                        continuation.resume(
                            throwing: MediaDraftProcessor.Failure.attachmentTooLarge(size)
                        )
                        return
                    }
                    guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                        continuation.resume(throwing: PhotoLibraryPickerError.noReadableMedia)
                        return
                    }
                    continuation.resume(returning: PhotoLibrarySelection(
                        data: data,
                        fileName: fileName,
                        typeIdentifier: typeIdentifier
                    ))
                }
            }
        }

        private static func mediaTypeIdentifier(from provider: NSItemProvider) -> String? {
            provider.registeredTypeIdentifiers.first { identifier in
                guard let type = UTType(identifier) else { return false }
                return type.conforms(to: .image) || type.conforms(to: .movie)
            } ?? {
                if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    return UTType.image.identifier
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
                    return UTType.movie.identifier
                }
                return nil
            }()
        }

        private static func fileName(suggestedName: String?, typeIdentifier: String) -> String? {
            let trimmed = suggestedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else {
                return UTType(typeIdentifier)?.preferredFilenameExtension.map { "attachment.\($0)" }
            }
            guard !trimmed.contains("."),
                  let fileExtension = UTType(typeIdentifier)?.preferredFilenameExtension,
                  !fileExtension.isEmpty else {
                return trimmed
            }
            return "\(trimmed).\(fileExtension)"
        }
    }
}
