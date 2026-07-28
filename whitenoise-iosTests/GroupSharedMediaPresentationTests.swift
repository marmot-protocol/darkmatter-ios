import Testing
@testable import whitenoise_ios
@testable import MarmotKit

struct GroupSharedMediaPresentationTests {
    @Test func splitsVisualMediaFromOtherFilesAndSortsNewestFirst() {
        let image = mediaRecord(
            messageID: "image-message",
            index: 0,
            mediaType: "image/jpeg",
            fileName: "photo.jpg",
            timestamp: 20
        )
        let video = mediaRecord(
            messageID: "video-message",
            index: 0,
            mediaType: "video/mp4",
            fileName: "clip.mp4",
            timestamp: 30
        )
        let document = mediaRecord(
            messageID: "document-message",
            index: 1,
            mediaType: "application/pdf",
            fileName: "notes.pdf",
            timestamp: 10
        )

        let items = GroupSharedMediaPresentation.items(from: [document, image, video])
        let visual = GroupSharedMediaPresentation.visualItems(from: items)
        let files = SharedMediaLibraryPresentation.fileItems(from: items)

        #expect(items.map(\.attachment.fileName) == ["clip.mp4", "photo.jpg", "notes.pdf"])
        #expect(visual.map(\.attachment.fileName) == ["clip.mp4", "photo.jpg"])
        #expect(files.map(\.attachment.fileName) == ["notes.pdf"])
    }

    @Test func attachmentIdentityIncludesOwningMessageAndIndex() {
        let first = mediaRecord(
            messageID: "message-a",
            index: 0,
            mediaType: "image/jpeg",
            fileName: "same.jpg",
            timestamp: 10
        )
        let second = mediaRecord(
            messageID: "message-b",
            index: 1,
            mediaType: "image/jpeg",
            fileName: "same.jpg",
            timestamp: 10
        )

        let items = GroupSharedMediaPresentation.items(from: [first, second])

        #expect(Set(items.map(\.id)).count == 2)
        #expect(Set(items.map(\.attachment.id)).count == 2)
    }

    @Test func duplicateRecordsWithoutMessageIDsRemainDistinctAndStable() {
        let record = mediaRecord(
            messageID: "",
            index: 0,
            mediaType: "image/jpeg",
            fileName: "same.jpg",
            timestamp: 10
        )

        let firstProjection = GroupSharedMediaPresentation.items(from: [record, record])
        let secondProjection = GroupSharedMediaPresentation.items(from: [record, record])

        #expect(Set(firstProjection.map(\.id)).count == 2)
        #expect(Set(firstProjection.map(\.attachment.id)).count == 2)
        #expect(firstProjection.map(\.id) == secondProjection.map(\.id))
    }
}

private func mediaRecord(
    messageID: String,
    index: UInt32,
    mediaType: String,
    fileName: String,
    timestamp: UInt64
) -> MediaRecordFfi {
    let hashSeed = String(messageID.utf8.reduce(0) { $0 &+ UInt64($1) }, radix: 16)
    let hash = String(repeating: "0", count: max(0, 64 - hashSeed.count)) + hashSeed
    return MediaRecordFfi(
        messageIdHex: messageID,
        attachmentIndex: index,
        direction: "received",
        groupIdHex: String(repeating: "ab", count: 32),
        sender: String(repeating: "cd", count: 32),
        reference: MediaAttachmentReferenceFfi(
            locators: [MediaLocatorFfi(kind: "blossom-v1", value: "https://example.com/media")],
            ciphertextSha256: String(repeating: "1", count: 64),
            plaintextSha256: hash,
            nonceHex: String(repeating: "2", count: 24),
            fileName: fileName,
            mediaType: mediaType,
            version: .v1,
            sourceEpoch: 1,
            dim: nil,
            thumbhash: nil
        ),
        caption: nil,
        recordedAt: timestamp,
        receivedAt: timestamp
    )
}
