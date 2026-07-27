import Foundation
import MarmotKit

extension MarkdownDocumentFfi {
    static var emptyDocument: MarkdownDocumentFfi {
        MarkdownDocumentFfi(blocks: [], truncated: false)
    }
}

extension EncryptedMediaVersionFfi {
    init?(wireValue: String) {
        switch wireValue {
        case "encrypted-media-v1":
            self = .v1
        case "encrypted-media-v2":
            self = .v2
        default:
            return nil
        }
    }

    var wireValue: String {
        switch self {
        case .v1:
            return "encrypted-media-v1"
        case .v2:
            return "encrypted-media-v2"
        }
    }
}

extension AppGroupEncryptedMediaComponentFfi {
    init(
        componentId: UInt32,
        component: String,
        required: Bool,
        mediaFormat: String,
        allowedLocatorKinds: [String],
        defaultBlobEndpoints: [AppBlobEndpointFfi]
    ) {
        self.init(
            componentId: componentId,
            component: component,
            required: required,
            version: EncryptedMediaVersionFfi(wireValue: mediaFormat),
            mediaFormat: mediaFormat,
            allowedLocatorKinds: allowedLocatorKinds,
            defaultBlobEndpoints: defaultBlobEndpoints
        )
    }
}

extension MediaAttachmentReferenceFfi {
    init(
        locators: [MediaLocatorFfi],
        ciphertextSha256: String,
        plaintextSha256: String,
        nonceHex: String,
        fileName: String,
        mediaType: String,
        version: String,
        sourceEpoch: UInt64,
        dim: String?,
        thumbhash: String?
    ) {
        self.init(
            locators: locators,
            ciphertextSha256: ciphertextSha256,
            plaintextSha256: plaintextSha256,
            nonceHex: nonceHex,
            fileName: fileName,
            mediaType: mediaType,
            version: EncryptedMediaVersionFfi(wireValue: version) ?? .v1,
            sourceEpoch: sourceEpoch,
            dim: dim,
            thumbhash: thumbhash
        )
    }
}

extension AppGroupRecordFfi {
    init(
        groupIdHex: String,
        endpoint: String,
        name: String,
        description: String,
        admins: [String],
        relays: [String],
        nostrGroupIdHex: String,
        avatarUrl: String?,
        avatarDim: String?,
        avatarThumbhash: String?,
        imageHashHex: String? = nil,
        encryptedMedia: AppGroupEncryptedMediaComponentFfi,
        disappearingMessageSecs: UInt64 = 0,
        archived: Bool,
        pendingConfirmation: Bool,
        selfMembership: SelfMembershipFfi = .member,
        welcomerAccountIdHex: String?,
        viaWelcomeMessageIdHex: String?
    ) {
        self.init(
            groupIdHex: groupIdHex,
            protocolProfile: .current,
            endpoint: endpoint,
            profilePresent: true,
            name: name,
            description: description,
            admins: admins,
            relays: relays,
            nostrGroupIdHex: nostrGroupIdHex,
            avatarUrl: avatarUrl,
            avatarDim: avatarDim,
            avatarThumbhash: avatarThumbhash,
            imageHashHex: imageHashHex,
            encryptedMedia: encryptedMedia,
            disappearingMessageSecs: disappearingMessageSecs,
            archived: archived,
            pendingConfirmation: pendingConfirmation,
            unrecoverable: false,
            selfMembership: selfMembership,
            welcomerAccountIdHex: welcomerAccountIdHex,
            viaWelcomeMessageIdHex: viaWelcomeMessageIdHex
        )
    }
}

extension NotificationUpdateFfi {
    init(
        notificationKey: String,
        conversationKey: String,
        trigger: NotificationTriggerFfi,
        accountRef: String,
        accountIdHex: String,
        groupIdHex: String,
        groupName: String?,
        isDm: Bool,
        isMention: Bool,
        messageIdHex: String?,
        sender: NotificationUserFfi,
        receiver: NotificationUserFfi,
        previewText: String?,
        reactionEmoji: String?,
        reactedToPreview: String?,
        timestampMs: Int64,
        isFromSelf: Bool
    ) {
        self.init(
            notificationKey: notificationKey,
            conversationKey: conversationKey,
            trigger: trigger,
            trafficClass: .standard,
            accountRef: accountRef,
            accountIdHex: accountIdHex,
            groupIdHex: groupIdHex,
            groupName: groupName,
            isDm: isDm,
            isMention: isMention,
            messageIdHex: messageIdHex,
            sender: sender,
            receiver: receiver,
            previewText: previewText,
            reactionEmoji: reactionEmoji,
            reactedToPreview: reactedToPreview,
            timestampMs: timestampMs,
            isFromSelf: isFromSelf
        )
    }
}

extension ChatListRowFfi {
    init(
        groupIdHex: String,
        archived: Bool,
        pendingConfirmation: Bool,
        title: String,
        groupName: String,
        avatarUrl: String?,
        avatar: ChatListAvatarFfi?,
        lastMessage: ChatListMessagePreviewFfi?,
        unreadCount: UInt64,
        hasUnread: Bool,
        unreadMentionCount: UInt64,
        unreadMention: Bool,
        firstUnreadMessageIdHex: String?,
        lastReadMessageIdHex: String?,
        lastReadTimelineAt: UInt64?,
        updatedAt: UInt64
    ) {
        self.init(
            groupIdHex: groupIdHex,
            archived: archived,
            pendingConfirmation: pendingConfirmation,
            title: title,
            groupName: groupName,
            avatarUrl: avatarUrl,
            avatar: avatar,
            lastMessage: lastMessage,
            unreadCount: unreadCount,
            hasUnread: hasUnread,
            unreadMentionCount: unreadMentionCount,
            unreadMention: unreadMention,
            firstUnreadMessageIdHex: firstUnreadMessageIdHex,
            lastReadMessageIdHex: lastReadMessageIdHex,
            lastReadTimelineAt: lastReadTimelineAt,
            conversationCreatedAt: updatedAt,
            activitySortAt: updatedAt,
            updatedAt: updatedAt,
            selfMembership: .member
        )
    }

    init(
        groupIdHex: String,
        archived: Bool,
        pendingConfirmation: Bool,
        title: String,
        groupName: String,
        avatarUrl: String?,
        avatar: ChatListAvatarFfi?,
        lastMessage: ChatListMessagePreviewFfi?,
        unreadCount: UInt64,
        hasUnread: Bool,
        unreadMentionCount: UInt64,
        unreadMention: Bool,
        firstUnreadMessageIdHex: String?,
        lastReadMessageIdHex: String?,
        lastReadTimelineAt: UInt64?,
        updatedAt: UInt64,
        selfMembership: SelfMembershipFfi
    ) {
        self.init(
            groupIdHex: groupIdHex,
            archived: archived,
            pendingConfirmation: pendingConfirmation,
            title: title,
            groupName: groupName,
            avatarUrl: avatarUrl,
            avatar: avatar,
            lastMessage: lastMessage,
            unreadCount: unreadCount,
            hasUnread: hasUnread,
            unreadMentionCount: unreadMentionCount,
            unreadMention: unreadMention,
            firstUnreadMessageIdHex: firstUnreadMessageIdHex,
            lastReadMessageIdHex: lastReadMessageIdHex,
            lastReadTimelineAt: lastReadTimelineAt,
            conversationCreatedAt: updatedAt,
            activitySortAt: updatedAt,
            updatedAt: updatedAt,
            selfMembership: selfMembership
        )
    }
}

extension AccountSummaryFfi {
    init(
        label: String,
        accountIdHex: String,
        localSigning: Bool,
        signedOut: Bool,
        running: Bool
    ) {
        self.init(
            label: label,
            accountIdHex: accountIdHex,
            localSigning: localSigning,
            externalSigning: false,
            signedOut: signedOut,
            running: running
        )
    }
}

extension SendSummaryFfi {
    init(published: UInt32, messageIds: [String]) {
        self.init(
            published: published,
            messageIds: messageIds,
            maintenanceDisposition: .ready
        )
    }
}

extension AppMessageRecordFfi {
    init(
        messageIdHex: String,
        direction: String,
        groupIdHex: String,
        sender: String,
        plaintext: String,
        contentTokens: MarkdownDocumentFfi,
        kind: UInt64,
        tags: [MessageTagFfi],
        recordedAt: UInt64,
        receivedAt: UInt64
    ) {
        self.init(
            messageIdHex: messageIdHex,
            direction: direction,
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: plaintext,
            contentTokens: contentTokens,
            kind: kind,
            tags: tags,
            sourceEpoch: nil,
            retentionSeconds: nil,
            retentionExpiresAt: nil,
            recordedAt: recordedAt,
            receivedAt: receivedAt
        )
    }

    init(
        messageIdHex: String,
        direction: String,
        groupIdHex: String,
        sender: String,
        plaintext: String,
        kind: UInt64,
        tags: [MessageTagFfi],
        recordedAt: UInt64,
        receivedAt: UInt64
    ) {
        self.init(
            messageIdHex: messageIdHex,
            direction: direction,
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: plaintext,
            contentTokens: .emptyDocument,
            kind: kind,
            tags: tags,
            sourceEpoch: nil,
            retentionSeconds: nil,
            retentionExpiresAt: nil,
            recordedAt: recordedAt,
            receivedAt: receivedAt
        )
    }
}

extension ReceivedMessageFfi {
    init(
        messageIdHex: String,
        groupIdHex: String,
        sender: String,
        senderDisplayName: String?,
        plaintext: String,
        contentTokens: MarkdownDocumentFfi,
        kind: UInt64,
        tags: [MessageTagFfi],
        recordedAt: UInt64
    ) {
        self.init(
            messageIdHex: messageIdHex,
            groupIdHex: groupIdHex,
            sender: sender,
            senderDisplayName: senderDisplayName,
            plaintext: plaintext,
            contentTokens: contentTokens,
            kind: kind,
            tags: tags,
            sourceEpoch: 0,
            retentionSeconds: nil,
            retentionExpiresAt: nil,
            recordedAt: recordedAt,
            receivedAt: 0
        )
    }

    init(
        messageIdHex: String,
        groupIdHex: String,
        sender: String,
        senderDisplayName: String?,
        plaintext: String,
        kind: UInt64,
        tags: [MessageTagFfi],
        recordedAt: UInt64
    ) {
        self.init(
            messageIdHex: messageIdHex,
            groupIdHex: groupIdHex,
            sender: sender,
            senderDisplayName: senderDisplayName,
            plaintext: plaintext,
            contentTokens: .emptyDocument,
            kind: kind,
            tags: tags,
            sourceEpoch: 0,
            retentionSeconds: nil,
            retentionExpiresAt: nil,
            recordedAt: recordedAt,
            receivedAt: 0
        )
    }
}

extension ChatListMessagePreviewFfi {
    init(
        messageIdHex: String,
        sender: String,
        senderDisplayName: String?,
        plaintext: String,
        kind: UInt64,
        timelineAt: UInt64,
        deleted: Bool
    ) {
        self.init(
            messageIdHex: messageIdHex,
            sender: sender,
            senderDisplayName: senderDisplayName,
            plaintext: plaintext,
            contentTokens: .emptyDocument,
            kind: kind,
            timelineAt: timelineAt,
            deleted: deleted
        )
    }
}

extension TimelineMessageRecordFfi {
    init(
        messageIdHex: String,
        sourceMessageIdHex: String?,
        direction: String,
        groupIdHex: String,
        sender: String,
        plaintext: String,
        kind: UInt64,
        tags: [MessageTagFfi],
        timelineAt: UInt64,
        receivedAt: UInt64,
        replyToMessageIdHex: String?,
        replyPreview: TimelineReplyPreviewFfi?,
        mediaJson: String?,
        media: [MediaAttachmentReferenceFfi] = [],
        agentTextStreamJson: String?,
        groupSystem: GroupSystemEventFfi? = nil,
        reactions: TimelineReactionSummaryFfi,
        deleted: Bool,
        deletedByMessageIdHex: String?,
        invalidationStatus: String?
    ) {
        self.init(
            messageIdHex: messageIdHex,
            sourceMessageIdHex: sourceMessageIdHex,
            direction: direction,
            groupIdHex: groupIdHex,
            sender: sender,
            plaintext: plaintext,
            contentTokens: .emptyDocument,
            kind: kind,
            tags: tags,
            timelineAt: timelineAt,
            receivedAt: receivedAt,
            replyToMessageIdHex: replyToMessageIdHex,
            replyPreview: replyPreview,
            mediaJson: mediaJson,
            media: media,
            agentTextStreamJson: agentTextStreamJson,
            groupSystem: groupSystem,
            reactions: reactions,
            deleted: deleted,
            deletedByMessageIdHex: deletedByMessageIdHex,
            invalidationStatus: invalidationStatus
        )
    }
}

extension TimelineReplyPreviewFfi {
    init(
        messageIdHex: String,
        sender: String,
        plaintext: String,
        kind: UInt64,
        mediaJson: String?,
        media: [MediaAttachmentReferenceFfi] = [],
        agentTextStreamJson: String?,
        deleted: Bool
    ) {
        self.init(
            messageIdHex: messageIdHex,
            sender: sender,
            plaintext: plaintext,
            contentTokens: .emptyDocument,
            kind: kind,
            mediaJson: mediaJson,
            media: media,
            agentTextStreamJson: agentTextStreamJson,
            deleted: deleted,
            invalidationStatus: nil
        )
    }
}
