import SwiftUI
import UIKit
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

    private let visualPreviewSideLength: CGFloat = 68

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    ZStack(alignment: .topTrailing) {
                        preview(for: attachment)

                        Button {
                            onRemove(attachment.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 19, weight: .semibold))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(Color(.systemBackground), Color.primary.opacity(0.82))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove attachment")
                        .offset(x: 7, y: -7)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)
        }
        .background(Color(.systemBackground).opacity(0.86))
    }

    @ViewBuilder
    private func preview(for attachment: MediaDraftAttachment) -> some View {
        switch attachment.kind {
        case .image, .video:
            ZStack {
                thumbnail(for: attachment)
                if attachment.kind == .video {
                    VideoPreviewPlayOverlay(
                        diameter: VideoPreviewOverlayPresentation.diameter(
                            for: CGSize(width: visualPreviewSideLength, height: visualPreviewSideLength)
                        )
                    )
                }
            }
            .frame(width: visualPreviewSideLength, height: visualPreviewSideLength)
            .clipShape(.rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            }
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
            .frame(width: 142, height: 68)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
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
            .frame(width: 112, height: 68)
            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
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
    let onSelection: ([PhotoLibrarySelection]) -> Void
    let onError: (Error) -> Void
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelection: onSelection, onError: onError, onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var configuration = PHPickerConfiguration(photoLibrary: .shared())
        configuration.filter = .any(of: [.images, .videos])
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
