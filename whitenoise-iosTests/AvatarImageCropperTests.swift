import Testing
import UIKit
@testable import whitenoise_ios

struct AvatarImageCropperTests {
    @Test func cropOffsetNeverExposesEmptyCanvas() {
        let offset = AvatarImageCropper.clampedOffset(
            CGSize(width: 500, height: -500),
            imageSize: CGSize(width: 800, height: 400),
            cropSide: 200,
            zoom: 1
        )

        #expect(offset.width == 100)
        #expect(offset.height == 0)
    }

    @Test func squareCropProducesSquareJPEG() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 400, height: 200),
            format: format
        ).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        }
        let sourceData = try #require(image.jpegData(compressionQuality: 1))
        let source = try #require(AvatarImageCropper.normalizedImage(from: sourceData))
        let data = try #require(AvatarImageCropper.croppedJPEG(
            image: source,
            cropSide: 200,
            zoom: 1,
            offset: .zero
        ))
        let cropped = try #require(UIImage(data: data))

        #expect(cropped.size.width == cropped.size.height)
        #expect(cropped.size.width == 200)
    }
}
