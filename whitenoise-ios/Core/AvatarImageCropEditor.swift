import SwiftUI
import UIKit

/// Raw image data awaiting the same square crop treatment regardless of
/// whether it came from Photos, Files, or a web-search result.
struct AvatarImageCropSource: Identifiable {
    let id = UUID()
    let data: Data
    let fileName: String?
    let typeIdentifier: String?
    let sourceURL: URL?
}

enum AvatarImageCropper {
    static let maximumZoom: CGFloat = 6

    static func normalizedImage(from data: Data) -> UIImage? {
        guard let image = UIImage(data: data) else { return nil }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
    }

    static func clampedOffset(
        _ offset: CGSize,
        imageSize: CGSize,
        cropSide: CGFloat,
        zoom: CGFloat
    ) -> CGSize {
        let baseScale = max(cropSide / imageSize.width, cropSide / imageSize.height)
        let displayedSize = CGSize(
            width: imageSize.width * baseScale * zoom,
            height: imageSize.height * baseScale * zoom
        )
        let maximumX = max(0, (displayedSize.width - cropSide) / 2)
        let maximumY = max(0, (displayedSize.height - cropSide) / 2)
        return CGSize(
            width: min(max(offset.width, -maximumX), maximumX),
            height: min(max(offset.height, -maximumY), maximumY)
        )
    }

    static func croppedJPEG(
        image: UIImage,
        cropSide: CGFloat,
        zoom: CGFloat,
        offset: CGSize
    ) -> Data? {
        guard let cgImage = image.cgImage else { return nil }
        let imageSize = image.size
        let baseScale = max(cropSide / imageSize.width, cropSide / imageSize.height)
        let displayScale = baseScale * zoom
        let cropLength = cropSide / displayScale
        let origin = CGPoint(
            x: (imageSize.width - cropLength) / 2 - offset.width / displayScale,
            y: (imageSize.height - cropLength) / 2 - offset.height / displayScale
        )
        let rect = CGRect(origin: origin, size: CGSize(width: cropLength, height: cropLength))
            .integral
            .intersection(CGRect(origin: .zero, size: imageSize))
        guard rect.width > 0, rect.height > 0,
              let cropped = cgImage.cropping(to: rect)
        else { return nil }
        return UIImage(cgImage: cropped).jpegData(compressionQuality: 0.92)
    }
}

struct AvatarImageCropEditor: View {
    @Environment(\.dismiss) private var dismiss

    let source: AvatarImageCropSource
    let onCrop: (AvatarImageCropSource, Data) -> Void

    @State private var image: UIImage?
    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    private let cropSide: CGFloat = 300

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let image {
                    cropCanvas(image)
                } else {
                    ContentUnavailableView("Image", systemImage: "photo")
                }

                Text("Pinch to zoom, then drag to position the image.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Spacer(minLength: 0)
            }
            .padding(.top, 24)
            .navigationTitle("Crop image")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use Image") {
                        guard let image,
                              let data = AvatarImageCropper.croppedJPEG(
                                image: image,
                                cropSide: cropSide,
                                zoom: zoom,
                                offset: offset
                              )
                        else { return }
                        onCrop(source, data)
                        dismiss()
                    }
                    .disabled(image == nil)
                }
            }
        }
        .interactiveDismissDisabled()
        .onAppear {
            image = AvatarImageCropper.normalizedImage(from: source.data)
        }
    }

    private func cropCanvas(_ image: UIImage) -> some View {
        let imageSize = image.size
        return ZStack {
            Color.black
            Image(uiImage: image)
                .resizable()
                .frame(
                    width: imageSize.width * baseScale(for: imageSize) * zoom,
                    height: imageSize.height * baseScale(for: imageSize) * zoom
                )
                .offset(offset)
        }
        .frame(width: cropSide, height: cropSide)
        .clipShape(.rect(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(.white.opacity(0.55), lineWidth: 1)
        }
        .gesture(dragGesture(imageSize: imageSize).simultaneously(with: magnificationGesture(imageSize: imageSize)))
        .accessibilityLabel("Crop image")
    }

    private func baseScale(for imageSize: CGSize) -> CGFloat {
        max(cropSide / imageSize.width, cropSide / imageSize.height)
    }

    private func dragGesture(imageSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                offset = AvatarImageCropper.clampedOffset(
                    CGSize(
                        width: committedOffset.width + value.translation.width,
                        height: committedOffset.height + value.translation.height
                    ),
                    imageSize: imageSize,
                    cropSide: cropSide,
                    zoom: zoom
                )
            }
            .onEnded { _ in
                committedOffset = offset
            }
    }

    private func magnificationGesture(imageSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoom = min(max(committedZoom * value, 1), AvatarImageCropper.maximumZoom)
                offset = AvatarImageCropper.clampedOffset(
                    offset,
                    imageSize: imageSize,
                    cropSide: cropSide,
                    zoom: zoom
                )
            }
            .onEnded { _ in
                committedZoom = zoom
                committedOffset = offset
            }
    }
}
