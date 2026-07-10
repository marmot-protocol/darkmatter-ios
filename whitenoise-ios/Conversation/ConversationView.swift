import SwiftUI
import UIKit
import MarmotKit

enum TimelineBottom {
    static let pinnedThreshold: CGFloat = 44
    static let overscrollRepairThreshold: CGFloat = 8

    static func isPinned(bottomY: CGFloat, viewportBottomY: CGFloat) -> Bool {
        bottomY <= viewportBottomY + pinnedThreshold
    }

    static func distanceToBottom(
        contentHeight: CGFloat,
        visibleBottomY: CGFloat,
        bottomContentInset: CGFloat = 0
    ) -> CGFloat {
        max(0, contentHeight + bottomContentInset - visibleBottomY)
    }

    static func shouldShowScrollToBottomButton(distanceToBottom: CGFloat) -> Bool {
        distanceToBottom > pinnedThreshold
    }

    static func shouldFollowViewportChange(wasPinned: Bool) -> Bool {
        wasPinned
    }

    static func shouldFollowProjectionChange(
        isPinned: Bool,
        isInitialBottomPositioning: Bool,
        hasTargetMessage: Bool
    ) -> Bool {
        isPinned || (isInitialBottomPositioning && !hasTargetMessage)
    }

    static func pinnedStateAfterScrollButtonTap(currentIsPinned: Bool) -> Bool {
        true
    }

    static func shouldPreservePinAfterContentGrowth(
        previous: TimelineBottomViewport,
        current: TimelineBottomViewport
    ) -> Bool {
        previous.isPinned && current.contentHeight > previous.contentHeight
    }

    static func overscrollPastBottom(
        contentHeight: CGFloat,
        visibleBottomY: CGFloat,
        bottomContentInset: CGFloat = 0
    ) -> CGFloat {
        max(0, visibleBottomY - (contentHeight + bottomContentInset))
    }

    static func shouldRepairBottomOverscroll(_ viewport: TimelineBottomViewport) -> Bool {
        viewport.overscrollPastBottom > overscrollRepairThreshold
    }
}

struct TimelineBottomViewport: Equatable {
    let contentHeight: CGFloat
    let visibleBottomY: CGFloat
    let bottomContentInset: CGFloat

    var distanceToBottom: CGFloat {
        TimelineBottom.distanceToBottom(
            contentHeight: contentHeight,
            visibleBottomY: visibleBottomY,
            bottomContentInset: bottomContentInset
        )
    }

    var overscrollPastBottom: CGFloat {
        TimelineBottom.overscrollPastBottom(
            contentHeight: contentHeight,
            visibleBottomY: visibleBottomY,
            bottomContentInset: bottomContentInset
        )
    }

    var shouldShowScrollToBottomButton: Bool {
        TimelineBottom.shouldShowScrollToBottomButton(distanceToBottom: distanceToBottom)
    }

    var isPinned: Bool {
        !shouldShowScrollToBottomButton
    }
}

enum MessageActionsPlacement: Equatable {
    case below
    case above
    case centered

    static func resolve(
        rowFrame: CGRect?,
        contentTopY: CGFloat,
        contentBottomY: CGFloat,
        menuEstimate: CGFloat
    ) -> MessageActionsPlacement {
        guard let rowFrame else { return .centered }

        let spaceBelow = contentBottomY - rowFrame.maxY
        let spaceAbove = rowFrame.minY - contentTopY
        if spaceBelow >= menuEstimate {
            return .below
        }
        if spaceAbove >= menuEstimate {
            return .above
        }
        return .centered
    }
}

enum TimelineBottomScrollReason: Equatable {
    case contentGrowth
    case timelineChange
    case viewportChange
    case buttonTap

    var isUserInitiated: Bool {
        self == .buttonTap
    }
}

enum TimelineInitialTargetScrollPolicy {
    static func isPositioning(hasTargetMessage: Bool, didFinishPositioning: Bool) -> Bool {
        hasTargetMessage && !didFinishPositioning
    }

    static func shouldSuppressBottomScroll(
        hasTargetMessage: Bool,
        didFinishPositioning: Bool,
        reason: TimelineBottomScrollReason
    ) -> Bool {
        isPositioning(
            hasTargetMessage: hasTargetMessage,
            didFinishPositioning: didFinishPositioning
        ) && !reason.isUserInitiated
    }
}

struct TimelineBottomScrollRequest: Equatable {
    let animated: Bool
    let reason: TimelineBottomScrollReason
    let targetID: String?

    func coalesced(with next: TimelineBottomScrollRequest) -> TimelineBottomScrollRequest {
        if next.reason.isUserInitiated {
            return next
        }
        if reason.isUserInitiated {
            return self
        }
        return TimelineBottomScrollRequest(
            animated: animated && next.animated,
            reason: next.reason,
            targetID: next.targetID ?? targetID
        )
    }
}

enum TimelineBottomScrollCoordinator {
    static func coalesced(
        _ current: TimelineBottomScrollRequest?,
        with next: TimelineBottomScrollRequest
    ) -> TimelineBottomScrollRequest {
        guard let current else { return next }
        return current.coalesced(with: next)
    }

    static func shouldSkipTimelineChangeScroll(
        lastAutomaticTargetID: String?,
        nextTargetID: String?
    ) -> Bool {
        guard let nextTargetID else { return false }
        return nextTargetID == lastAutomaticTargetID
    }
}

enum ScrollViewBottomClamp {
    static let tolerance: CGFloat = 0.5

    static func legalBottomOffsetY(
        contentHeight: CGFloat,
        boundsHeight: CGFloat,
        adjustedTopInset: CGFloat,
        adjustedBottomInset: CGFloat
    ) -> CGFloat {
        max(-adjustedTopInset, contentHeight - boundsHeight + adjustedBottomInset)
    }
}

enum TimelinePaginationTrigger {
    static func shouldRequestPage(hasMore: Bool, isTriggerAlreadyVisible: Bool) -> Bool {
        hasMore && !isTriggerAlreadyVisible
    }
}

private struct ConversationRuntimeStartToken: Equatable {
    let runtimeGeneration: Int
    let isRuntimeWarmingUp: Bool
}

private struct ConversationDraftLoadToken: Equatable {
    let accountRef: String?
    let groupIdHex: String
}

struct ConversationSendPayload {
    let viewModel: ConversationViewModel
    let text: String
    let attachments: [MediaDraftAttachment]
}

enum ConversationSendPreparation {
    static func prepare(
        draft: inout String,
        mediaDrafts: inout [MediaDraftAttachment],
        viewModel: ConversationViewModel?
    ) -> ConversationSendPayload? {
        guard let viewModel else { return nil }
        let text = draft
        let attachments = mediaDrafts
        guard !attachments.isEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        draft = ""
        mediaDrafts = []
        return ConversationSendPayload(viewModel: viewModel, text: text, attachments: attachments)
    }
}

enum TimelineInitialScroll {
    static let bottomStabilizationDelayNanoseconds: UInt64 = 120_000_000

    static func shouldStartAtBottom(hasItems: Bool, didPerformInitialScroll: Bool) -> Bool {
        destination(
            hasItems: hasItems,
            didPerformInitialScroll: didPerformInitialScroll,
            targetMessageIdHex: nil,
            targetItemId: nil
        ) == .bottom
    }

    static func destination(
        hasItems: Bool,
        didPerformInitialScroll: Bool,
        targetMessageIdHex: String?,
        targetItemId: String?
    ) -> TimelineInitialDestination {
        guard hasItems, !didPerformInitialScroll else { return .none }
        if targetMessageIdHex?.isEmpty == false {
            guard let targetItemId, !targetItemId.isEmpty else { return .none }
            return .item(targetItemId)
        }
        return .bottom
    }

    static func shouldConcealContent(
        hasItems: Bool,
        didFinishInitialPositioning: Bool,
        targetMessageIdHex: String?,
        targetItemId: String?
    ) -> Bool {
        guard hasItems, !didFinishInitialPositioning else { return false }
        if targetMessageIdHex?.isEmpty == false {
            return true
        }
        return true
    }

    static func shouldSettleBottom(isMediaRecordsRefreshPending: Bool) -> Bool {
        !isMediaRecordsRefreshPending
    }
}

enum TimelineInitialDestination: Equatable {
    case none
    case bottom
    case item(String)
}

enum TimelineInitialTargetResolution: Equatable {
    case ready
    case loadOlder
    case waitForPagination
    case fallbackToBottom
}

enum TimelineInitialTargetPolicy {
    static func resolve(
        targetMessageIdHex: String?,
        targetItemId: String?,
        hasMoreBefore: Bool,
        canLoadOlder: Bool
    ) -> TimelineInitialTargetResolution {
        guard targetMessageIdHex?.isEmpty == false else { return .ready }
        if targetItemId?.isEmpty == false { return .ready }
        guard hasMoreBefore else { return .fallbackToBottom }
        return canLoadOlder ? .loadOlder : .waitForPagination
    }
}

enum TimelineViewportVisibility {
    static func visibleRowKeys(
        frames: [String: CGRect],
        viewport: CGRect
    ) -> Set<String> {
        guard !viewport.isEmpty else { return [] }
        return Set(frames.compactMap { key, frame in
            guard !frame.isNull,
                  !frame.isEmpty,
                  frame.intersects(viewport),
                  frame.intersection(viewport).height > 0.5
            else { return nil }
            return key
        })
    }
}

enum TimelineUnreadDivider {
    static func shouldShow(
        before item: TimelineItem,
        firstUnreadMessageIdHex: String?
    ) -> Bool {
        guard let firstUnreadMessageIdHex,
              !firstUnreadMessageIdHex.isEmpty,
              case .message(let record, _) = item.kind
        else { return false }
        return record.messageIdHex == firstUnreadMessageIdHex
    }
}

enum ReplyPreviewLayout {
    enum CloseAlignment {
        case trailing

        var swiftUI: Alignment {
            switch self {
            case .trailing: .trailing
            }
        }
    }

    static let leadingContentInset: CGFloat = 14
    static let closeTrailingInset = leadingContentInset
    static let contentTopInset: CGFloat = 5
    static let contentBottomInset = contentTopInset
    static let closeHitSize: CGFloat = 44
    static let closeIconSize: CGFloat = 20
    static let closeAlignment: CloseAlignment = .trailing
    static let outerHorizontalInset: CGFloat = 10
    static let outerTopInset: CGFloat = 2
    static let outerBottomInset: CGFloat = 2
}

nonisolated struct ConversationChromePresentation: Equatable {
    let title: String
    let subtitle: String?

    static func initial(
        chat: AppGroupRecordFfi,
        initialTitle: String?,
        initialMemberCount: Int?
    ) -> ConversationChromePresentation {
        ConversationChromePresentation(
            title: ContentSanitizer.groupName(initialTitle)
                ?? ContentSanitizer.groupName(chat.name)
                ?? IdentityFormatter.short(chat.groupIdHex),
            subtitle: initialMemberCount.flatMap(memberSubtitle)
        )
    }

    static func memberSubtitle(for memberCount: Int) -> String? {
        if memberCount == 0 { return L10n.string("Just you") }
        return L10n.plural("%lld members", Int64(memberCount))
    }
}

/// What the conversation header's secondary line shows. While the runtime is
/// (re)starting after a background suspension, live reads are briefly blocked,
/// so the header surfaces a transient "Connecting…" status in place of the
/// static member subtitle rather than letting the screen look frozen.
enum ConversationHeaderSecondary: Equatable {
    case connecting
    case subtitle(String?)

    static func resolve(isRuntimeWarmingUp: Bool, subtitle: String?) -> ConversationHeaderSecondary {
        isRuntimeWarmingUp ? .connecting : .subtitle(subtitle)
    }
}

/// What the timeline area shows while it holds no rows. The `connecting` state
/// distinguishes a runtime warming up after a background resume (a network wait
/// worth labelling) from a brief steady-state local read, so the content area
/// reads as "catching up" rather than a contextless spinner.
enum ConversationEmptyState: Equatable {
    case error
    case connecting
    case loading
    case empty

    static func resolve(hasError: Bool, isLoading: Bool, isRuntimeWarmingUp: Bool) -> ConversationEmptyState {
        if hasError { return .error }
        if isLoading { return isRuntimeWarmingUp ? .connecting : .loading }
        return .empty
    }
}

enum ConversationInvitePresentation {
    static func hasMessage(in timeline: [TimelineItem]) -> Bool {
        timeline.contains { item in
            if case .message = item.kind { return true }
            return false
        }
    }

    static func shouldShowCenteredPrompt(
        isPending: Bool,
        hasError: Bool,
        isLoading: Bool,
        timeline: [TimelineItem]
    ) -> Bool {
        isPending
            && !hasError
            && !isLoading
            && !hasMessage(in: timeline)
    }
}

private struct InitialBottomScrollClamp: UIViewRepresentable {
    let isEnabled: Bool

    func makeUIView(context: Context) -> InitialBottomScrollClampView {
        let view = InitialBottomScrollClampView()
        view.isClampEnabled = isEnabled
        return view
    }

    func updateUIView(_ uiView: InitialBottomScrollClampView, context: Context) {
        uiView.isClampEnabled = isEnabled
        uiView.clampToBottomIfNeeded()
    }
}

private final class InitialBottomScrollClampView: UIView {
    var isClampEnabled = false {
        didSet {
            guard isClampEnabled else { return }
            clampToBottomIfNeeded()
        }
    }

    private weak var resolvedScrollView: UIScrollView?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        resolvedScrollView = enclosingScrollView()
        clampToBottomIfNeeded()
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        resolvedScrollView = enclosingScrollView()
        clampToBottomIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        clampToBottomIfNeeded()
    }

    func clampToBottomIfNeeded() {
        guard isClampEnabled else { return }
        guard let scrollView = resolvedScrollView ?? enclosingScrollView() else { return }
        resolvedScrollView = scrollView
        scrollView.layoutIfNeeded()
        let targetY = ScrollViewBottomClamp.legalBottomOffsetY(
            contentHeight: scrollView.contentSize.height,
            boundsHeight: scrollView.bounds.height,
            adjustedTopInset: scrollView.adjustedContentInset.top,
            adjustedBottomInset: scrollView.adjustedContentInset.bottom
        )
        guard abs(scrollView.contentOffset.y - targetY) > ScrollViewBottomClamp.tolerance else { return }
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: targetY), animated: false)
    }

    private func enclosingScrollView() -> UIScrollView? {
        var candidate = superview
        while let view = candidate {
            if let scrollView = view as? UIScrollView {
                return scrollView
            }
            candidate = view.superview
        }
        return nil
    }
}

struct ConversationView: View {
    @Environment(AppState.self) private var appState
    let chat: AppGroupRecordFfi
    let draftAccountRef: String?
    let initialTitle: String?
    let initialOtherMember: String?
    let initialMemberCount: Int?
    let initialTargetMessageIdHex: String?
    let initialUnreadMessageIdHex: String?
    let forwardDestinationProvider: (() async throws -> [MessageForwardDestination])?
    let onChatListRowUpdated: ((ChatListRowFfi) -> Void)?
    let onGroupChanged: ((AppGroupRecordFfi) -> Void)?
    let onGroupLeft: ((String) -> Void)?
    let onGroupDeleted: ((String) -> Void)?
    let onDraftChanged: (() -> Void)?

    @State private var viewModel: ConversationViewModel?
    @State private var draft: String = ""
    @State private var mediaDrafts: [MediaDraftAttachment] = []
    @StateObject private var voiceRecorder = VoiceMessageRecorder()
    @State private var showCameraCapture = false
    @State private var showPhotoLibraryPicker = false
    @State private var showFileImporter = false
    @State private var showDetails = false
    @State private var actionsTarget: ActionsTarget?
    @State private var emojiPickerTarget: ActionsTarget?
    @State private var messageInfoTarget: ActionsTarget?
    @State private var reactionDetailsTarget: ReactionDetailsTarget?
    @State private var forwardTarget: ActionsTarget?
    @State private var editTarget: ActionsTarget?
    /// When the long-pressed bubble sits too low for the actions popover to fit
    /// below it, flip the popover above the bubble instead.
    @State private var actionsAbove = false
    /// When a bubble is so tall that neither above nor below has room, drop the
    /// popover and show the menu as a centered overlay over the bubble instead.
    @State private var actionsCentered = false
    @State private var rowFrames = RowFrameStore()
    @State private var timelineVisibility = TimelineVisibilityStore()
    @State private var measuredActionRowFrameKey: String?
    @State private var pendingActionFrameMeasurementClearTask: Task<Void, Never>?
    @State private var composerFocusRequest = 0
    @State private var isAtTimelineBottom = true
    @State private var didPerformInitialBottomScroll = false
    @State private var isInitialTimelinePositionSettled = false
    @State private var initialScrollFollowUpTask: Task<Void, Never>?
    @State private var pendingBottomScrollRequest: TimelineBottomScrollRequest?
    @State private var pendingBottomScrollTask: Task<Void, Never>?
    @State private var isOlderTimelineTriggerVisible = false
    @State private var isNewerTimelineTriggerVisible = false
    @State private var lastAutomaticBottomScrollTargetID: String?
    @State private var isInitialBottomStabilizationScheduled = false
    @State private var pendingKeyboardDismissTask: Task<Void, Never>?
    @State private var visibleChatRoute: VisibleChatRoute?
    /// Global Y bounds of the visible timeline (between nav bar and composer).
    /// The bottom shrinks when the keyboard rises, so placement accounts for it.
    @State private var contentTopY: CGFloat = 0
    @State private var contentBottomY: CGFloat = 0

    private static let timelineBottomID = "conversation-timeline-bottom"
    private static let timelineCoordinateSpace = "conversation-timeline-viewport"
    private static let actionFrameMeasurementClearDelayNanoseconds: UInt64 = 250_000_000

    private struct ActionsTarget: Identifiable {
        let record: AppMessageRecordFfi
        let status: MessageStatus
        let id = UUID()
    }

    private struct ReactionDetailsTarget: Identifiable {
        let messageIdHex: String
        let initialEmoji: String
        let id = UUID()
    }

    init(
        chat: AppGroupRecordFfi,
        accountRef: String? = nil,
        initialTitle: String? = nil,
        initialOtherMember: String? = nil,
        initialMemberCount: Int? = nil,
        initialTargetMessageIdHex: String? = nil,
        initialUnreadMessageIdHex: String? = nil,
        initialAppState: AppState? = nil,
        forwardDestinationProvider: (() async throws -> [MessageForwardDestination])? = nil,
        onChatListRowUpdated: ((ChatListRowFfi) -> Void)? = nil,
        onGroupChanged: ((AppGroupRecordFfi) -> Void)? = nil,
        onGroupLeft: ((String) -> Void)? = nil,
        onGroupDeleted: ((String) -> Void)? = nil,
        onDraftChanged: (() -> Void)? = nil
    ) {
        self.chat = chat
        self.draftAccountRef = accountRef ?? initialAppState?.activeAccountRef
        self.initialTitle = initialTitle
        self.initialOtherMember = initialOtherMember
        self.initialMemberCount = initialMemberCount
        self.forwardDestinationProvider = forwardDestinationProvider
        self.onChatListRowUpdated = onChatListRowUpdated
        self.onGroupChanged = onGroupChanged
        self.onGroupLeft = onGroupLeft
        self.onGroupDeleted = onGroupDeleted
        self.onDraftChanged = onDraftChanged
        let targetMessageId = initialTargetMessageIdHex?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.initialTargetMessageIdHex = targetMessageId?.isEmpty == false ? targetMessageId : nil
        let unreadMessageId = initialUnreadMessageIdHex?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.initialUnreadMessageIdHex = unreadMessageId?.isEmpty == false ? unreadMessageId : nil
        _viewModel = State(
            initialValue: initialAppState.map {
                ConversationViewModel(
                    appState: $0,
                    group: chat,
                    initialTitle: initialTitle,
                    initialOtherMember: initialOtherMember,
                    initialMemberCount: initialMemberCount,
                    onChatListRowUpdated: onChatListRowUpdated
                )
            }
        )
    }

    /// Binding that's `true` only for the row matching `actionsTarget`, so the
    /// floating actions popover anchors to the long-pressed bubble.
    private func actionsBinding(for record: AppMessageRecordFfi) -> Binding<Bool> {
        Binding(
            get: {
                !actionsCentered
                    && actionsTarget?.record.messageIdHex == record.messageIdHex
                    && !record.messageIdHex.isEmpty
            },
            set: { shown in if !shown { dismissActions() } }
        )
    }

    var body: some View {
        timeline
            .bottomInputChromeAccessory { composerArea }
            .overlay { centeredActionsOverlay }
            .navigationTitle(conversationChrome.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    conversationTitle
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showDetails = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("Group details")
                }
            }
            .sheet(isPresented: $showDetails) {
                if let viewModel {
                    NavigationStack {
                        GroupDetailsView(
                            viewModel: viewModel,
                            onGroupChanged: { group in
                                onGroupChanged?(group)
                            },
                            onGroupLeft: { groupIdHex in
                                showDetails = false
                                onGroupLeft?(groupIdHex)
                            },
                            onGroupDeleted: { groupIdHex in
                                showDetails = false
                                onGroupDeleted?(groupIdHex)
                            }
                        )
                    }
                    .appAppearance()
                }
            }
            .sheet(item: $emojiPickerTarget) { target in
                if let viewModel {
                    EmojiPickerSheet(onPick: { emoji in
                        Task { await viewModel.toggleReaction(emoji, on: target.record) }
                        appState.addRecentReaction(emoji)
                    })
                    .appAppearance()
                }
            }
            .sheet(item: $messageInfoTarget) { target in
                MessageInfoSheet(record: target.record, status: target.status)
                    .appAppearance()
            }
            .sheet(item: $reactionDetailsTarget) { target in
                if let viewModel {
                    ReactionDetailsSheet(
                        details: viewModel.reactionDetails(for: target.messageIdHex),
                        initialEmoji: target.initialEmoji
                    )
                    .appAppearance()
                }
            }
            .sheet(item: $forwardTarget) { target in
                if let viewModel {
                    ForwardMessageSheet(
                        message: target.record,
                        viewModel: viewModel,
                        destinationProvider: {
                            if let forwardDestinationProvider {
                                return try await forwardDestinationProvider()
                            }
                            return try await viewModel.forwardDestinations()
                        }
                    )
                        .appAppearance()
                }
            }
            .sheet(item: $editTarget) { target in
                if let viewModel {
                    EditMessageSheet(message: target.record, viewModel: viewModel)
                        .appAppearance()
                }
            }
            .sheet(isPresented: $showCameraCapture) {
                CameraCaptureView(
                    onImage: { image in
                        showCameraCapture = false
                        addCameraImage(image)
                    },
                    onCancel: {
                        showCameraCapture = false
                    }
                )
                .ignoresSafeArea()
            }
            .sheet(isPresented: $showPhotoLibraryPicker) {
                PhotoLibraryPickerView(
                    selectionLimit: remainingMediaDraftSlots,
                    onSelection: addPhotoLibrarySelections,
                    onError: { error in
                        appState.present(.error(L10n.string("Couldn't add attachment"), message: error.localizedDescription))
                    },
                    onDismiss: {
                        showPhotoLibraryPicker = false
                    }
                )
                .ignoresSafeArea()
            }
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: MediaAttachmentPolicy.fileImporterAllowedTypes,
                allowsMultipleSelection: true,
                onCompletion: addFileImporterResult
            )
            .task(id: ConversationRuntimeStartToken(
                runtimeGeneration: appState.runtimeGeneration,
                isRuntimeWarmingUp: appState.isRuntimeWarmingUp
            )) {
                if viewModel == nil {
                    viewModel = ConversationViewModel(
                        appState: appState,
                        group: chat,
                        initialTitle: initialTitle,
                        initialOtherMember: initialOtherMember,
                        initialMemberCount: initialMemberCount,
                        onChatListRowUpdated: onChatListRowUpdated
                    )
                }
                await viewModel?.start()
            }
            .task(id: ConversationDraftLoadToken(
                accountRef: draftAccountRef,
                groupIdHex: chat.groupIdHex
            )) {
                await restorePersistedDraft()
            }
            .onChange(of: appState.streamingDebugEnabled) { _, _ in
                viewModel?.refreshStreamingDebugPresentation()
            }
            .onChange(of: appState.profileRefreshGeneration) { _, _ in
                viewModel?.refreshProfileDependentTimelineProjections()
            }
            .onReceive(NotificationCenter.default.publisher(for: AppLanguage.didChangeNotification)) { _ in
                viewModel?.refreshProfileDependentTimelineProjections()
            }
            .onChange(of: viewModel?.canSendMessages ?? true) { _, canSendMessages in
                handleComposerAvailabilityChange(canSendMessages: canSendMessages)
            }
            .onChange(of: draft) { _, draft in
                persistDraft(draft)
            }
            .onAppear {
                visibleChatRoute = appState.beginViewingChat(groupIdHex: chat.groupIdHex)
            }
            .onDisappear {
                if let visibleChatRoute {
                    appState.endViewingChat(visibleChatRoute)
                }
                voiceRecorder.cancelIfActive()
                cancelPendingTimelineFollowUpWork()
                dismissKeyboard()
                persistDraft(draft)
                onDraftChanged?()
                Task { await appState.conversationDraftStore.flush() }
            }
    }

    // MARK: - Composer + reply

    @ViewBuilder
    private var composerArea: some View {
        if let viewModel, viewModel.hasPendingInvite {
            inviteResponseArea(viewModel: viewModel)
        } else {
            VStack(spacing: 0) {
                if let viewModel, let replyingTo = viewModel.replyingTo {
                    replyBar(for: replyingTo, viewModel: viewModel)
                }
                let inlineAudioDraft = ComposerMediaDraftPresentation.inlineAudioDraft(in: mediaDrafts)
                let mentionCandidates = inlineAudioDraft == nil ? (viewModel?.mentionCandidates(for: draft) ?? []) : []
                let stripAttachments = ComposerMediaDraftPresentation.stripAttachments(from: mediaDrafts)
                if !stripAttachments.isEmpty {
                    MediaDraftStrip(attachments: stripAttachments) { id in
                        removeMediaDraft(id)
                    }
                }
                if voiceRecorder.isActive {
                    VoiceRecordingBanner(
                        samples: voiceRecorder.waveformSamples,
                        durationSeconds: voiceRecorder.durationSeconds,
                        isLocked: voiceRecorder.isLocked,
                        onCancel: cancelVoiceRecording,
                        onStop: stopLockedVoiceRecording
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                ComposerBar(
                    draft: $draft,
                    isSending: viewModel?.sendInFlight ?? false,
                    hasAttachments: !mediaDrafts.isEmpty,
                    audioDraft: inlineAudioDraft,
                    mediaEnabled: viewModel?.canSendMediaAttachments ?? false,
                    disabledMessage: viewModel?.inactiveGroupMessage,
                    voiceRecordingActive: voiceRecorder.isActive,
                    focusRequest: composerFocusRequest,
                    mentionCandidates: mentionCandidates,
                    onTakePhoto: takePhoto,
                    onPhotoLibrary: openPhotoLibrary,
                    onAttachFile: openFileImporter,
                    onRemoveAudioDraft: removeMediaDraft,
                    onVoicePressBegan: beginVoicePress,
                    onVoiceDragChanged: updateVoiceDrag,
                    onVoicePressEnded: endVoicePress,
                    onMentionSelect: { candidate in
                        viewModel?.applyMentionSelection(candidate, to: &draft)
                    },
                    onSend: send
                )
            }
            .keyboardAdaptiveBottomPadding()
        }
    }

    private func inviteResponseArea(viewModel: ConversationViewModel) -> some View {
        VStack(spacing: 12) {
            Text(invitationText(viewModel: viewModel))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 12) {
                Button {
                    acceptInvite(viewModel: viewModel)
                } label: {
                    inviteActionLabel(
                        title: L10n.string("Accept"),
                        isLoading: viewModel.inviteActionInFlight == .accepting
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(role: .destructive) {
                    declineInvite(viewModel: viewModel)
                } label: {
                    inviteActionLabel(
                        title: L10n.string("Decline"),
                        isLoading: viewModel.inviteActionInFlight == .declining
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.red)
            }
            .disabled(viewModel.inviteActionInFlight != nil)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private func inviteActionLabel(title: String, isLoading: Bool) -> some View {
        Group {
            if isLoading {
                ProgressView()
            } else {
                Text(title)
            }
        }
        .font(.headline)
        .frame(maxWidth: .infinity, minHeight: 32)
    }

    private func replyBar(for record: AppMessageRecordFfi, viewModel: ConversationViewModel) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor)
                .frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.formatted("Replying to %@", appState.displayName(forAccountIdHex: record.sender)))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .shadow(color: .black.opacity(0.28), radius: 1.5, y: 1)
                Text(ContentSanitizer.singleLine(viewModel.displayBody(of: record), maxLength: 100) ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.22), radius: 1, y: 1)
            }
            Spacer()
            Button {
                viewModel.replyingTo = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: ReplyPreviewLayout.closeIconSize, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(
                        width: ReplyPreviewLayout.closeHitSize,
                        height: ReplyPreviewLayout.closeHitSize,
                        alignment: ReplyPreviewLayout.closeAlignment.swiftUI
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel reply")
        }
        .padding(.leading, ReplyPreviewLayout.leadingContentInset)
        .padding(.trailing, ReplyPreviewLayout.closeTrailingInset)
        .padding(.top, ReplyPreviewLayout.contentTopInset)
        .padding(.bottom, ReplyPreviewLayout.contentBottomInset)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color(.secondarySystemBackground).opacity(0.82))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .padding(.horizontal, ReplyPreviewLayout.outerHorizontalInset)
        .padding(.top, ReplyPreviewLayout.outerTopInset)
        .padding(.bottom, ReplyPreviewLayout.outerBottomInset)
    }

    @ViewBuilder
    private var conversationTitle: some View {
        let chrome = conversationChrome
        VStack(spacing: 0) {
            Text(chrome.title)
                .font(.headline)
                .lineLimit(1)
            conversationHeaderSecondary(subtitle: chrome.subtitle)
        }
    }

    @ViewBuilder
    private func conversationHeaderSecondary(subtitle: String?) -> some View {
        switch ConversationHeaderSecondary.resolve(
            isRuntimeWarmingUp: appState.isRuntimeWarmingUp,
            subtitle: subtitle
        ) {
        case .connecting:
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text(L10n.string("Connecting…"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        case .subtitle(let value):
            Text(value ?? " ")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .opacity(value == nil ? 0 : 1)
        }
    }

    private var conversationChrome: ConversationChromePresentation {
        if let viewModel {
            return ConversationChromePresentation(
                title: viewModel.displayTitle,
                subtitle: viewModel.displaySubtitle
            )
        }
        return .initial(
            chat: chat,
            initialTitle: initialTitle,
            initialMemberCount: initialMemberCount
        )
    }

    private func invitationText(viewModel: ConversationViewModel) -> String {
        let inviterName = viewModel.inviterAccountIdHex.map {
            appState.displayName(forAccountIdHex: $0)
        } ?? L10n.string("Someone")
        return L10n.formatted("%@ has invited you to a secure chat", inviterName)
    }

    // MARK: - Timeline

    @ViewBuilder
    private var timeline: some View {
        if let viewModel {
            if ConversationInvitePresentation.shouldShowCenteredPrompt(
                isPending: viewModel.hasPendingInvite,
                hasError: viewModel.error != nil,
                isLoading: viewModel.isLoading,
                timeline: viewModel.timeline
            ) {
                Text(invitationText(viewModel: viewModel))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 36)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.timeline.isEmpty {
                switch ConversationEmptyState.resolve(
                    hasError: viewModel.error != nil,
                    isLoading: viewModel.isLoading,
                    isRuntimeWarmingUp: appState.isRuntimeWarmingUp
                ) {
                case .error:
                    ContentUnavailableView {
                        Label("Couldn't load conversation", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(viewModel.error ?? "")
                    } actions: {
                        Button("Retry") {
                            Task { await viewModel.start() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                case .connecting:
                    // The local snapshot hasn't landed yet because the runtime is
                    // still warming up; label the wait instead of a bare spinner.
                    ContentUnavailableView {
                        Label {
                            Text(L10n.string("Connecting…"))
                        } icon: {
                            ProgressView()
                        }
                    }
                case .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .empty:
                    ContentUnavailableView(
                        "No messages yet",
                        systemImage: "bubble.middle.bottom",
                        description: Text("Send the first message to get started.")
                    )
                }
            } else {
                let concealInitialTimeline = shouldConcealInitialTimelineContent(viewModel: viewModel)
                ScrollViewReader { proxy in
                    GeometryReader { outer in
                        ScrollView {
                            VStack(spacing: 0) {
                                LazyVStack(alignment: .leading, spacing: 4) {
                                    olderTimelineTrigger(viewModel: viewModel)
                                    ForEach(viewModel.timeline) { item in
                                        if TimelineUnreadDivider.shouldShow(
                                            before: item,
                                            firstUnreadMessageIdHex: initialUnreadMessageIdHex
                                        ) {
                                            UnreadMessagesDivider()
                                                .id(unreadDividerID(for: initialUnreadMessageIdHex ?? ""))
                                        }
                                        row(for: item, viewModel: viewModel)
                                            .background {
                                                GeometryReader { rowGeometry in
                                                    Color.clear.preference(
                                                        key: TimelineRowViewportFramesKey.self,
                                                        value: [
                                                            TimelineRowViewportFrame(
                                                                key: item.rowFrameKey,
                                                                frame: rowGeometry.frame(
                                                                    in: .named(Self.timelineCoordinateSpace)
                                                                )
                                                            )
                                                        ]
                                                    )
                                                }
                                            }
                                    }
                                    .padding(.bottom, 4)
                                    newerTimelineTrigger(viewModel: viewModel)
                                }
                                timelineBottomSentinel
                            }
                            .padding(.top, 8)
                            .padding(.bottom, 2)
                            .background {
                                InitialBottomScrollClamp(
                                    isEnabled: isInitialBottomPositioning(viewModel: viewModel)
                                )
                                .frame(width: 0, height: 0)
                            }
                        }
                        .overlay(alignment: .bottomTrailing) {
                            scrollToBottomButton(proxy: proxy, viewModel: viewModel)
                        }
                        .opacity(concealInitialTimeline ? 0 : 1)
                        .allowsHitTesting(!concealInitialTimeline)
                        .accessibilityHidden(concealInitialTimeline)
                        .overlay {
                            if concealInitialTimeline {
                                ProgressView()
                            }
                        }
                        .coordinateSpace(name: Self.timelineCoordinateSpace)
                        .defaultScrollAnchor(.bottom)
                        .compatibleBottomScrollEdgeEffect()
                        .scrollDismissesKeyboard(.interactively)
                        .simultaneousGesture(TapGesture().onEnded { scheduleKeyboardDismiss() })
                        .onPreferenceChange(RowFramesKey.self) { rowFrames.replace(with: $0) }
                        .onPreferenceChange(TimelineRowViewportFramesKey.self) { preferences in
                            let visibleRowsChanged = timelineVisibility.replace(
                                preferences: preferences,
                                viewport: CGRect(origin: .zero, size: outer.size)
                            )
                            if visibleRowsChanged {
                                markCurrentlyVisibleMessagesRead(viewModel: viewModel)
                            }
                        }
                        .onScrollGeometryChange(for: TimelineBottomViewport.self) { geometry in
                            TimelineBottomViewport(
                                contentHeight: geometry.contentSize.height,
                                visibleBottomY: geometry.visibleRect.maxY,
                                bottomContentInset: geometry.contentInsets.bottom
                            )
                        } action: { previous, current in
                            if isInitialTargetPositioning {
                                // The scroll view initially reports its default
                                // bottom anchor before the unread-divider jump
                                // has landed. Do not let that transient geometry
                                // re-arm bottom following.
                                isAtTimelineBottom = false
                            } else if isInitialBottomPositioning(viewModel: viewModel) {
                                isAtTimelineBottom = true
                                scheduleInitialBottomStabilization(proxy: proxy, viewModel: viewModel)
                            } else if TimelineBottom.shouldRepairBottomOverscroll(current) {
                                isAtTimelineBottom = true
                                scheduleScrollToBottom(
                                    proxy: proxy,
                                    animated: false,
                                    reason: .viewportChange,
                                    targetID: viewModel.timeline.last?.id
                                )
                            } else if TimelineBottom.shouldPreservePinAfterContentGrowth(
                                previous: previous,
                                current: current
                            ) {
                                isAtTimelineBottom = true
                                scheduleScrollToBottom(
                                    proxy: proxy,
                                    animated: true,
                                    reason: .contentGrowth,
                                    targetID: viewModel.timeline.last?.id
                                )
                            } else {
                                isAtTimelineBottom = current.isPinned
                            }
                        }
                        .onChange(of: viewModel.timeline.last?.id) { _, newId in
                            guard newId != nil else { return }
                            if performInitialScrollIfNeeded(proxy: proxy, viewModel: viewModel) {
                                return
                            }
                            settleInitialTimelinePositionIfNoScrollNeeded(viewModel: viewModel)
                            if isAtTimelineBottom {
                                scheduleScrollToBottom(
                                    proxy: proxy,
                                    animated: true,
                                    reason: .timelineChange,
                                    targetID: newId
                                )
                            }
                        }
                        .onChange(of: viewModel.timelineProjectionGeneration) { _, _ in
                            handleTimelineProjectionChange(proxy: proxy, viewModel: viewModel)
                        }
                        .onChange(of: outer.size.height) { _, _ in
                            let wasAtBottom = isAtTimelineBottom
                            contentTopY = outer.frame(in: .global).minY
                            contentBottomY = outer.frame(in: .global).maxY
                            if TimelineBottom.shouldFollowViewportChange(wasPinned: wasAtBottom) {
                                scheduleScrollToBottom(
                                    proxy: proxy,
                                    animated: false,
                                    reason: .viewportChange,
                                    targetID: viewModel.timeline.last?.id
                                )
                            }
                        }
                        .onAppear {
                            contentTopY = outer.frame(in: .global).minY
                            contentBottomY = outer.frame(in: .global).maxY
                            if !performInitialScrollIfNeeded(proxy: proxy, viewModel: viewModel) {
                                settleInitialTimelinePositionIfNoScrollNeeded(viewModel: viewModel)
                            }
                        }
                        .onDisappear {
                            initialScrollFollowUpTask?.cancel()
                            initialScrollFollowUpTask = nil
                            isInitialBottomStabilizationScheduled = false
                            cancelPendingBottomScroll()
                        }
                    }
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func row(for item: TimelineItem, viewModel: ConversationViewModel) -> some View {
        switch item.kind {
        case .message(let record, let status):
            if let groupSystemText = viewModel.groupSystemDisplayText(for: record) {
                GroupSystemEventRow(text: groupSystemText)
                    .id(item.id)
            } else if let agentDisplay = AgentEventPresentation.display(for: record) {
                AgentEventRow(
                    senderName: appState.displayName(forAccountIdHex: record.sender),
                    display: agentDisplay,
                    debugStyle: appState.streamingDebugEnabled
                        ? MessageSemantics.debugStyle(for: record)
                        : nil
                )
                .id(item.id)
            } else {
                agentMessageBubbleRow(
                    for: item,
                    record: record,
                    status: status,
                    viewModel: viewModel
                )
            }
        case .systemEvent(let event):
            SystemEventRow(event: event)
                .id(item.id)
        case .streamDebugEvent(let event):
            StreamDebugEventRow(event: event)
                .id(item.id)
        }
    }

    @ViewBuilder
    private func agentMessageBubbleRow(
        for item: TimelineItem,
        record: AppMessageRecordFfi,
        status: MessageStatus,
        viewModel: ConversationViewModel
    ) -> some View {
        let debugStyle = appState.streamingDebugEnabled
            ? MessageSemantics.debugStyle(for: record)
            : nil
        let allowsActions = debugStyle?.isUserVisibleBubble ?? true
        MessageBubble(
            record: record,
            status: status,
            debugStyle: debugStyle,
            isDeleted: viewModel.isDeleted(record.messageIdHex),
            isEdited: viewModel.isEdited(record.messageIdHex),
            replyPreview: viewModel.replyPreview(for: record),
            mediaItems: viewModel.mediaItems(for: item),
            markdownBlocks: viewModel.markdownDisplayBlocks(for: item),
            reactions: viewModel.reactions(for: record.messageIdHex),
            onShowReactionDetails: { emoji in
                reactionDetailsTarget = ReactionDetailsTarget(
                    messageIdHex: record.messageIdHex,
                    initialEmoji: emoji
                )
            },
            onLoadMedia: ConversationMediaLoader { media in
                try await viewModel.data(for: media)
            }
        )
        .replySwipeToReply(isEnabled: allowsActions && canReply(to: record, viewModel: viewModel)) {
            beginReply(to: record, viewModel: viewModel)
        }
        .background {
            if allowsActions, measuredActionRowFrameKey == item.rowFrameKey {
                GeometryReader { geo in
                    Color.clear.preference(
                        key: RowFramesKey.self,
                        value: [
                            RowFramePreference(
                                key: item.rowFrameKey,
                                frame: geo.frame(in: .global)
                            )
                        ]
                    )
                }
            }
        }
        .id(item.id)
        .onLongPressGesture(
            pressing: { pressing in
                updateActionFrameMeasurement(pressing: pressing, rowFrameKey: item.rowFrameKey)
            }
        ) {
            guard allowsActions,
                  !record.messageIdHex.isEmpty,
                  !viewModel.isDeleted(record.messageIdHex) else { return }
            Haptics.tap()
            presentActions(for: record, status: status, rowFrameKey: item.rowFrameKey)
            finishActionFrameMeasurement(rowFrameKey: item.rowFrameKey)
        }
        .popover(
            isPresented: actionsBinding(for: record),
            attachmentAnchor: .point(actionsAbove ? .top : .bottom),
            arrowEdge: actionsAbove ? .bottom : .top
        ) {
            actionsMenu(for: record, status: status, viewModel: viewModel)
        }
    }

    private var timelineBottomSentinel: some View {
        Color.clear
            .frame(height: 1)
            .id(Self.timelineBottomID)
    }

    @ViewBuilder
    private func olderTimelineTrigger(viewModel: ConversationViewModel) -> some View {
        if viewModel.hasMoreBefore || viewModel.isLoadingOlder {
            HStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .opacity(viewModel.isLoadingOlder ? 1 : 0.01)
                Spacer()
            }
            .frame(height: 28)
            .onAppear {
                let shouldRequest = TimelinePaginationTrigger.shouldRequestPage(
                    hasMore: viewModel.hasMoreBefore,
                    isTriggerAlreadyVisible: isOlderTimelineTriggerVisible
                )
                isOlderTimelineTriggerVisible = true
                guard shouldRequest else { return }
                Task { await viewModel.loadOlderTimelinePage() }
            }
            .onDisappear {
                isOlderTimelineTriggerVisible = false
            }
        }
    }

    @ViewBuilder
    private func newerTimelineTrigger(viewModel: ConversationViewModel) -> some View {
        if viewModel.hasMoreAfter || viewModel.isLoadingNewer {
            HStack {
                Spacer()
                ProgressView()
                    .controlSize(.small)
                    .opacity(viewModel.isLoadingNewer ? 1 : 0.01)
                Spacer()
            }
            .frame(height: 28)
            .onAppear {
                let shouldRequest = TimelinePaginationTrigger.shouldRequestPage(
                    hasMore: viewModel.hasMoreAfter,
                    isTriggerAlreadyVisible: isNewerTimelineTriggerVisible
                )
                isNewerTimelineTriggerVisible = true
                guard shouldRequest else { return }
                Task { await viewModel.loadNewerTimelinePage() }
            }
            .onDisappear {
                isNewerTimelineTriggerVisible = false
            }
        }
    }

    @ViewBuilder
    private func scrollToBottomButton(proxy: ScrollViewProxy, viewModel: ConversationViewModel) -> some View {
        if !isAtTimelineBottom || viewModel.hasMoreAfter {
            Button {
                Haptics.tap()
                if viewModel.hasMoreAfter {
                    Task { @MainActor in
                        await viewModel.loadNewerTimelinePage()
                        isAtTimelineBottom = TimelineBottom.pinnedStateAfterScrollButtonTap(
                            currentIsPinned: isAtTimelineBottom
                        )
                        jumpToBottom(proxy: proxy)
                    }
                } else {
                    isAtTimelineBottom = TimelineBottom.pinnedStateAfterScrollButtonTap(
                        currentIsPinned: isAtTimelineBottom
                    )
                    jumpToBottom(proxy: proxy)
                }
            } label: {
                Image(systemName: "arrow.down")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 42, height: 42)
                    .background {
                        ZStack {
                            Circle().fill(.regularMaterial)
                            Circle().fill(Color(.secondarySystemBackground).opacity(0.86))
                        }
                    }
                    .overlay {
                        Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Scroll to latest message")
            .padding(.trailing, 9)
            .padding(.bottom, 10)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool, targetID: String?) {
        if animated {
            withAnimation(.smooth(duration: 0.2)) {
                proxy.scrollTo(Self.timelineBottomID, anchor: .bottom)
            }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                proxy.scrollTo(Self.timelineBottomID, anchor: .bottom)
            }
        }
    }

    private func scheduleScrollToBottom(
        proxy: ScrollViewProxy,
        animated: Bool,
        reason: TimelineBottomScrollReason,
        targetID: String? = nil
    ) {
        guard !TimelineInitialTargetScrollPolicy.shouldSuppressBottomScroll(
            hasTargetMessage: initialTargetMessageIdHex != nil,
            didFinishPositioning: isInitialTimelinePositionSettled,
            reason: reason
        ) else { return }

        if reason == .timelineChange,
           TimelineBottomScrollCoordinator.shouldSkipTimelineChangeScroll(
               lastAutomaticTargetID: lastAutomaticBottomScrollTargetID,
               nextTargetID: targetID
           ) {
            return
        }

        let request = TimelineBottomScrollRequest(
            animated: animated,
            reason: reason,
            targetID: targetID
        )
        pendingBottomScrollRequest = TimelineBottomScrollCoordinator.coalesced(
            pendingBottomScrollRequest,
            with: request
        )
        pendingBottomScrollTask?.cancel()
        pendingBottomScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled, let request = pendingBottomScrollRequest else { return }
            pendingBottomScrollRequest = nil
            pendingBottomScrollTask = nil
            scrollToBottom(proxy: proxy, animated: request.animated, targetID: request.targetID)
            lastAutomaticBottomScrollTargetID = request.targetID
        }
    }

    private func cancelPendingBottomScroll() {
        pendingBottomScrollTask?.cancel()
        pendingBottomScrollTask = nil
        pendingBottomScrollRequest = nil
    }

    private func jumpToBottom(proxy: ScrollViewProxy) {
        // Keep the button as one animated scroll, but defer it through the same
        // coalescer as automatic follow-ups so it doesn't stack in the current
        // SwiftUI transaction (#44, #161).
        cancelPendingBottomScroll()
        scheduleScrollToBottom(
            proxy: proxy,
            animated: true,
            reason: .buttonTap,
            targetID: viewModel?.timeline.last?.id
        )
    }

    private func performInitialScrollIfNeeded(proxy: ScrollViewProxy, viewModel: ConversationViewModel) -> Bool {
        let targetItemId = initialTargetItemId(viewModel: viewModel)
        switch TimelineInitialTargetPolicy.resolve(
            targetMessageIdHex: initialTargetMessageIdHex,
            targetItemId: targetItemId,
            hasMoreBefore: viewModel.hasMoreBefore,
            canLoadOlder: viewModel.canLoadOlderTimelinePage
        ) {
        case .ready:
            break
        case .loadOlder:
            Task { await viewModel.loadOlderTimelinePage() }
            return true
        case .waitForPagination:
            return true
        case .fallbackToBottom:
            // A notification can point at a message that was deleted or aged
            // out. Once the complete local history has been searched, fall back
            // to the latest message instead of leaving the timeline concealed.
            didPerformInitialBottomScroll = true
            isInitialTimelinePositionSettled = false
            isAtTimelineBottom = true
            scheduleInitialBottomStabilization(proxy: proxy, viewModel: viewModel)
            return true
        }
        let destination = TimelineInitialScroll.destination(
            hasItems: !viewModel.timeline.isEmpty,
            didPerformInitialScroll: didPerformInitialBottomScroll,
            targetMessageIdHex: initialTargetMessageIdHex,
            targetItemId: targetItemId
        )
        switch destination {
        case .none:
            return false
        case .bottom:
            didPerformInitialBottomScroll = true
            isInitialTimelinePositionSettled = false
            isAtTimelineBottom = true
            scheduleInitialBottomStabilization(proxy: proxy, viewModel: viewModel)
        case .item(let itemId):
            cancelPendingBottomScroll()
            didPerformInitialBottomScroll = true
            isInitialTimelinePositionSettled = false
            isAtTimelineBottom = false
            let anchor = initialUnreadMessageIdHex == initialTargetMessageIdHex
                ? UnitPoint.top
                : UnitPoint.center
            scrollTo(itemId, proxy: proxy, anchor: anchor)
            scheduleInitialScrollFollowUp(
                .item(itemId),
                itemAnchor: anchor,
                proxy: proxy,
                viewModel: viewModel
            )
        }
        return true
    }

    private func handleTimelineProjectionChange(proxy: ScrollViewProxy, viewModel: ConversationViewModel) {
        guard !viewModel.timeline.isEmpty else { return }
        if performInitialScrollIfNeeded(proxy: proxy, viewModel: viewModel) {
            return
        }
        guard !isInitialTargetPositioning else {
            isAtTimelineBottom = false
            return
        }
        let shouldFollow = TimelineBottom.shouldFollowProjectionChange(
            isPinned: isAtTimelineBottom,
            isInitialBottomPositioning: didPerformInitialBottomScroll && !isInitialTimelinePositionSettled,
            hasTargetMessage: initialTargetMessageIdHex != nil
        )
        guard shouldFollow else { return }
        isAtTimelineBottom = true
        scheduleScrollToBottom(
            proxy: proxy,
            animated: false,
            reason: .contentGrowth,
            targetID: viewModel.timeline.last?.id
        )
    }

    private func scheduleInitialScrollFollowUp(
        _ destination: TimelineInitialDestination,
        itemAnchor: UnitPoint = .center,
        proxy: ScrollViewProxy,
        viewModel: ConversationViewModel
    ) {
        initialScrollFollowUpTask?.cancel()
        initialScrollFollowUpTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }

            switch destination {
            case .none:
                break
            case .bottom:
                scrollToBottom(proxy: proxy, animated: false, targetID: nil)
            case .item(let itemId):
                scrollTo(itemId, proxy: proxy, anchor: itemAnchor)
            }

            await Task.yield()
            guard !Task.isCancelled else { return }
            settleInitialTimelinePosition(viewModel: viewModel)
        }
    }

    private func isInitialBottomPositioning(viewModel: ConversationViewModel) -> Bool {
        didPerformInitialBottomScroll
            && !isInitialTimelinePositionSettled
            && initialTargetMessageIdHex == nil
            && !viewModel.timeline.isEmpty
    }

    private var isInitialTargetPositioning: Bool {
        TimelineInitialTargetScrollPolicy.isPositioning(
            hasTargetMessage: initialTargetMessageIdHex != nil,
            didFinishPositioning: isInitialTimelinePositionSettled
        )
    }

    private func scheduleInitialBottomStabilization(proxy: ScrollViewProxy, viewModel: ConversationViewModel) {
        guard !isInitialBottomStabilizationScheduled else { return }
        isInitialBottomStabilizationScheduled = true
        initialScrollFollowUpTask?.cancel()
        initialScrollFollowUpTask = Task { @MainActor in
            defer { isInitialBottomStabilizationScheduled = false }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: TimelineInitialScroll.bottomStabilizationDelayNanoseconds)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                scrollToBottom(proxy: proxy, animated: false, targetID: nil)
                isAtTimelineBottom = true
                guard TimelineInitialScroll.shouldSettleBottom(
                    isMediaRecordsRefreshPending: viewModel.isMediaRecordsRefreshPending
                ) else {
                    continue
                }
                settleInitialTimelinePosition(viewModel: viewModel)
                lastAutomaticBottomScrollTargetID = viewModel.timeline.last?.id
                return
            }
        }
    }

    private func shouldConcealInitialTimelineContent(viewModel: ConversationViewModel) -> Bool {
        TimelineInitialScroll.shouldConcealContent(
            hasItems: !viewModel.timeline.isEmpty,
            didFinishInitialPositioning: isInitialTimelinePositionSettled,
            targetMessageIdHex: initialTargetMessageIdHex,
            targetItemId: initialTargetItemId(viewModel: viewModel)
        )
    }

    private func settleInitialTimelinePositionIfNoScrollNeeded(viewModel: ConversationViewModel) {
        guard !shouldConcealInitialTimelineContent(viewModel: viewModel) else { return }
        settleInitialTimelinePosition(viewModel: viewModel)
    }

    private func timelineItemId(forMessageIdHex messageIdHex: String, viewModel: ConversationViewModel) -> String? {
        viewModel.timeline.first { item in
            guard case .message(let record, _) = item.kind else { return false }
            return record.messageIdHex == messageIdHex
        }?.id
    }

    private func initialTargetItemId(viewModel: ConversationViewModel) -> String? {
        guard let initialTargetMessageIdHex,
              timelineItemId(forMessageIdHex: initialTargetMessageIdHex, viewModel: viewModel) != nil
        else { return nil }
        if initialTargetMessageIdHex == initialUnreadMessageIdHex {
            return unreadDividerID(for: initialTargetMessageIdHex)
        }
        return timelineItemId(forMessageIdHex: initialTargetMessageIdHex, viewModel: viewModel)
    }

    private func unreadDividerID(for messageIdHex: String) -> String {
        "unread:\(messageIdHex)"
    }

    private func settleInitialTimelinePosition(viewModel: ConversationViewModel) {
        isInitialTimelinePositionSettled = true
        markCurrentlyVisibleMessagesRead(viewModel: viewModel)
    }

    private func markCurrentlyVisibleMessagesRead(viewModel: ConversationViewModel) {
        guard isInitialTimelinePositionSettled else { return }
        let visibleRowKeys = timelineVisibility.visibleRowKeys
        guard !visibleRowKeys.isEmpty else { return }
        let records = viewModel.timeline.compactMap { item -> AppMessageRecordFfi? in
            guard visibleRowKeys.contains(item.rowFrameKey),
                  case .message(let record, _) = item.kind
            else { return nil }
            return record
        }
        viewModel.markVisibleMessagesRead(records)
    }

    private func scrollTo(_ itemId: String, proxy: ScrollViewProxy, anchor: UnitPoint) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(itemId, anchor: anchor)
        }
    }

    private func canReply(to record: AppMessageRecordFfi, viewModel: ConversationViewModel) -> Bool {
        viewModel.canSendMessages
            && !record.messageIdHex.isEmpty
            && !viewModel.isDeleted(record.messageIdHex)
    }

    private func beginReply(to record: AppMessageRecordFfi, viewModel: ConversationViewModel) {
        guard canReply(to: record, viewModel: viewModel) else { return }
        viewModel.replyingTo = record
        composerFocusRequest += 1
    }

    private func acceptInvite(viewModel: ConversationViewModel) {
        Task {
            guard let updated = await viewModel.acceptInvite() else { return }
            onGroupChanged?(updated)
        }
    }

    private func declineInvite(viewModel: ConversationViewModel) {
        Task {
            guard let updated = await viewModel.declineInvite() else { return }
            onGroupChanged?(updated)
            onGroupLeft?(updated.groupIdHex)
        }
    }

    private func send() {
        guard viewModel?.canSendMessages == true else { return }
        guard let payload = ConversationSendPreparation.prepare(
            draft: &draft,
            mediaDrafts: &mediaDrafts,
            viewModel: viewModel
        ) else { return }
        Task {
            if payload.attachments.isEmpty {
                await payload.viewModel.send(payload.text)
            } else {
                await payload.viewModel.sendMedia(payload.attachments, caption: payload.text)
            }
        }
    }

    private func handleComposerAvailabilityChange(canSendMessages: Bool) {
        guard !canSendMessages else { return }
        draft = ""
        viewModel?.replyingTo = nil
        cancelVoiceRecording()
        showCameraCapture = false
        showPhotoLibraryPicker = false
        showFileImporter = false
        dismissKeyboard()
    }

    private func restorePersistedDraft() async {
        guard let draftAccountRef else { return }
        let draftBeforeLoad = draft
        await appState.conversationDraftStore.loadIfNeeded()
        guard !Task.isCancelled, draft == draftBeforeLoad else { return }
        draft = appState.conversationDraftStore.draft(
            accountRef: draftAccountRef,
            groupIdHex: chat.groupIdHex
        ) ?? ""
    }

    private func persistDraft(_ draft: String) {
        guard let draftAccountRef else { return }
        appState.conversationDraftStore.setDraft(
            draft,
            accountRef: draftAccountRef,
            groupIdHex: chat.groupIdHex
        )
    }

    private func takePhoto() {
        guard canBeginMediaSelection() else { return }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            appState.present(.warning(L10n.string("Camera is not available on this device")))
            return
        }
        showCameraCapture = true
    }

    private func openPhotoLibrary() {
        guard canBeginMediaSelection() else { return }
        showPhotoLibraryPicker = true
    }

    private func openFileImporter() {
        guard canBeginMediaSelection() else { return }
        showFileImporter = true
    }

    private func addCameraImage(_ image: UIImage) {
        Task { @MainActor in
            do {
                let attachment = try await MediaDraftProcessor.preparedAttachment(from: image, fileName: nil)
                try appendMediaDraft(attachment)
            } catch is CancellationError {
                return
            } catch {
                appState.present(.error(L10n.string("Couldn't add attachment"), message: error.localizedDescription))
            }
        }
    }

    private func addPhotoLibrarySelections(_ selections: [PhotoLibrarySelection]) {
        guard let viewModel, viewModel.canSendMediaAttachments else {
            appState.present(.warning(L10n.string("Media is not available in this group")))
            return
        }
        guard remainingMediaDraftSlots > 0 else {
            presentMaxAttachmentWarning()
            return
        }

        let selected = Array(selections.prefix(remainingMediaDraftSlots))
        if selected.count < selections.count {
            presentMaxAttachmentWarning()
        }

        Task { @MainActor in
            for selection in selected {
                do {
                    let attachment = try await MediaDraftProcessor.preparedAttachment(
                        from: selection.data,
                        fileName: selection.fileName,
                        typeIdentifier: selection.typeIdentifier
                    )
                    try appendMediaDraft(attachment)
                } catch is CancellationError {
                    return
                } catch {
                    appState.present(.error(L10n.string("Couldn't add attachment"), message: error.localizedDescription))
                }
            }
        }
    }

    private func addFileImporterResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            addFileAttachments(urls)
        case .failure(let error):
            appState.present(.error(L10n.string("Couldn't add attachment"), message: error.localizedDescription))
        }
    }

    private func addFileAttachments(_ urls: [URL]) {
        guard let viewModel, viewModel.canSendMediaAttachments else {
            appState.present(.warning(L10n.string("Media is not available in this group")))
            return
        }
        guard remainingMediaDraftSlots > 0 else {
            presentMaxAttachmentWarning()
            return
        }
        let selected = Array(urls.prefix(remainingMediaDraftSlots))
        if selected.count < urls.count {
            presentMaxAttachmentWarning()
        }

        Task { @MainActor in
            for url in selected {
                let isSecurityScoped = url.startAccessingSecurityScopedResource()
                defer {
                    if isSecurityScoped {
                        url.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    let attachment = try await MediaDraftProcessor.preparedAttachment(fromFileURL: url)
                    try appendMediaDraft(attachment)
                } catch is CancellationError {
                    return
                } catch {
                    appState.present(.error(L10n.string("Couldn't add attachment"), message: error.localizedDescription))
                }
            }
        }
    }

    private func beginVoicePress() {
        guard canBeginMediaSelection() else { return }
        voiceRecorder.beginPress { error in
            appState.present(.error(L10n.string("Couldn't record audio"), message: error.localizedDescription))
        }
    }

    private func updateVoiceDrag(_ translation: CGSize) {
        voiceRecorder.updateDrag(translation)
    }

    private func endVoicePress() {
        guard let result = voiceRecorder.endPress() else { return }
        addVoiceRecording(result)
    }

    private func stopLockedVoiceRecording() {
        guard let result = voiceRecorder.stopLockedRecording() else { return }
        addVoiceRecording(result)
    }

    private func cancelVoiceRecording() {
        voiceRecorder.cancel()
    }

    private func addVoiceRecording(_ result: VoiceRecordingResult) {
        Task { @MainActor in
            do {
                let attachment = try await MediaDraftProcessor.preparedVoiceAttachment(from: result)
                try appendMediaDraft(attachment)
            } catch is CancellationError {
                return
            } catch {
                appState.present(.error(L10n.string("Couldn't add attachment"), message: error.localizedDescription))
            }
        }
    }

    private var remainingMediaDraftSlots: Int {
        max(0, MediaDraftProcessor.maxAttachmentCount - mediaDrafts.count)
    }

    private func canBeginMediaSelection() -> Bool {
        guard let viewModel, viewModel.canSendMediaAttachments else {
            appState.present(.warning(L10n.string("Media is not available in this group")))
            return false
        }
        guard remainingMediaDraftSlots > 0 else {
            presentMaxAttachmentWarning()
            return false
        }
        return true
    }

    private func appendMediaDraft(_ attachment: MediaDraftAttachment) throws {
        if attachment.kind == .audio {
            mediaDrafts.removeAll { $0.kind == .audio }
        }
        guard mediaDrafts.count < MediaDraftProcessor.maxAttachmentCount else {
            presentMaxAttachmentWarning()
            return
        }
        mediaDrafts.append(attachment)
        if attachment.kind == .audio {
            draft = ""
            dismissKeyboard()
            return
        }
        composerFocusRequest += 1
    }

    private func removeMediaDraft(_ id: MediaDraftAttachment.ID) {
        mediaDrafts.removeAll { $0.id == id }
    }

    private func presentMaxAttachmentWarning() {
        appState.present(.warning(L10n.plural("You can send up to %lld attachments at once", Int64(MediaDraftProcessor.maxAttachmentCount))))
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    private func scheduleKeyboardDismiss() {
        pendingKeyboardDismissTask?.cancel()
        pendingKeyboardDismissTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            pendingKeyboardDismissTask = nil
            dismissKeyboard()
        }
    }

    private func cancelPendingKeyboardDismiss() {
        pendingKeyboardDismissTask?.cancel()
        pendingKeyboardDismissTask = nil
    }

    private func updateActionFrameMeasurement(pressing: Bool, rowFrameKey: String) {
        if pressing {
            pendingActionFrameMeasurementClearTask?.cancel()
            pendingActionFrameMeasurementClearTask = nil
            measuredActionRowFrameKey = rowFrameKey
        } else {
            scheduleActionFrameMeasurementClear(rowFrameKey: rowFrameKey)
        }
    }

    private func scheduleActionFrameMeasurementClear(rowFrameKey: String) {
        pendingActionFrameMeasurementClearTask?.cancel()
        pendingActionFrameMeasurementClearTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.actionFrameMeasurementClearDelayNanoseconds)
            guard !Task.isCancelled, measuredActionRowFrameKey == rowFrameKey else { return }
            measuredActionRowFrameKey = nil
            pendingActionFrameMeasurementClearTask = nil
        }
    }

    private func finishActionFrameMeasurement(rowFrameKey: String) {
        pendingActionFrameMeasurementClearTask?.cancel()
        pendingActionFrameMeasurementClearTask = nil
        if measuredActionRowFrameKey == rowFrameKey {
            measuredActionRowFrameKey = nil
        }
    }

    private func cancelActionFrameMeasurement() {
        pendingActionFrameMeasurementClearTask?.cancel()
        pendingActionFrameMeasurementClearTask = nil
        measuredActionRowFrameKey = nil
    }

    private func cancelPendingTimelineFollowUpWork() {
        initialScrollFollowUpTask?.cancel()
        initialScrollFollowUpTask = nil
        cancelPendingBottomScroll()
        cancelPendingKeyboardDismiss()
        cancelActionFrameMeasurement()
    }

    // MARK: - Message actions placement

    /// Decide where the actions menu opens for the long-pressed bubble: below it
    /// (default), flipped above it (no room below), or centered over it (the
    /// bubble is so tall neither end has room — a popover would land off-screen).
    private func presentActions(
        for record: AppMessageRecordFfi,
        status: MessageStatus,
        rowFrameKey: String
    ) {
        let placement = MessageActionsPlacement.resolve(
            rowFrame: rowFrames.frames[rowFrameKey],
            contentTopY: contentTopY,
            contentBottomY: contentBottomY,
            menuEstimate: Self.actionsMenuEstimate
        )

        switch placement {
        case .below:
            actionsAbove = false
            actionsCentered = false
            actionsTarget = ActionsTarget(record: record, status: status)
        case .above:
            actionsAbove = true
            actionsCentered = false
            actionsTarget = ActionsTarget(record: record, status: status)
        case .centered:
            actionsAbove = false
            withAnimation(.easeOut(duration: 0.15)) {
                actionsCentered = true
                actionsTarget = ActionsTarget(record: record, status: status)
            }
        }
    }

    private func dismissActions() {
        if actionsCentered {
            withAnimation(.easeOut(duration: 0.15)) {
                actionsTarget = nil
                actionsCentered = false
            }
        } else {
            actionsTarget = nil
            actionsCentered = false
        }
    }

    /// The centered, scrim-backed variant shown for over-tall bubbles. A normal
    /// bubble uses the anchored `.popover` in `row(for:)` instead.
    @ViewBuilder
    private var centeredActionsOverlay: some View {
        if actionsCentered, let viewModel, let target = actionsTarget {
            ZStack {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { dismissActions() }
                actionsMenu(for: target.record, status: target.status, viewModel: viewModel)
                    .background(.regularMaterial, in: .rect(cornerRadius: 16))
                    .shadow(radius: 24, y: 8)
            }
            .transition(.opacity)
        }
    }

    /// The shared actions menu, used both by the anchored popover and the
    /// centered overlay so their buttons stay in sync.
    private func actionsMenu(
        for record: AppMessageRecordFfi,
        status: MessageStatus,
        viewModel: ConversationViewModel
    ) -> some View {
        MessageActionsMenu(
            isMine: record.direction == "sent",
            canInteract: viewModel.canSendMessages,
            canForward: MessageForwardingPolicy.forwardableText(for: record) != nil,
            canEdit: MessageEditingPolicy.canEdit(
                record,
                isDeleted: viewModel.isDeleted(record.messageIdHex),
                canSendMessages: viewModel.canSendMessages
            ),
            quickReactions: appState.quickReactions,
            onReact: { emoji in
                Task { await viewModel.toggleReaction(emoji, on: record) }
                appState.addRecentReaction(emoji)
                dismissActions()
            },
            onReply: {
                dismissActions()
                beginReply(to: record, viewModel: viewModel)
            },
            onCopy: {
                SensitiveClipboard.copy(viewModel.displayBody(of: record))
                Haptics.tap()
                dismissActions()
            },
            onForward: {
                let target = ActionsTarget(record: record, status: status)
                dismissActions()
                forwardTarget = target
            },
            onEdit: {
                let target = ActionsTarget(record: record, status: status)
                dismissActions()
                editTarget = target
            },
            onInfo: {
                let target = ActionsTarget(record: record, status: status)
                dismissActions()
                messageInfoTarget = target
            },
            onDelete: {
                Task { await viewModel.deleteMessage(record) }
                dismissActions()
            },
            onMoreEmoji: {
                let target = record
                dismissActions()
                emojiPickerTarget = ActionsTarget(record: target, status: status)
            }
        )
    }

    /// Approximate height of the actions popover (reaction row + action rows +
    /// arrow). If neither end of the bubble has at least this much room, the
    /// menu is centered over the bubble instead of anchored to it.
    private static let actionsMenuEstimate: CGFloat = 430
}

/// Holds the latest on-screen frame of each message row. A reference type so
/// scroll-driven updates don't churn SwiftUI state; we only read it on demand
/// when a long press needs to decide which way the actions popover should open.
private final class RowFrameStore {
    private(set) var frames: [String: CGRect] = [:]

    func replace(with preferences: [RowFramePreference]) {
        var next: [String: CGRect] = [:]
        next.reserveCapacity(preferences.count)
        for preference in preferences {
            next[preference.key] = preference.frame
        }
        guard frames != next else { return }
        frames = next
    }
}

/// Keeps viewport geometry out of SwiftUI-observed state. Row frames update on
/// every scroll tick; the view only needs to react when the set of genuinely
/// intersecting timeline rows changes.
private final class TimelineVisibilityStore {
    private(set) var visibleRowKeys: Set<String> = []

    @discardableResult
    func replace(
        preferences: [TimelineRowViewportFrame],
        viewport: CGRect
    ) -> Bool {
        var frames: [String: CGRect] = [:]
        frames.reserveCapacity(preferences.count)
        for preference in preferences {
            frames[preference.key] = preference.frame
        }
        let next = TimelineViewportVisibility.visibleRowKeys(
            frames: frames,
            viewport: viewport
        )
        guard next != visibleRowKeys else { return false }
        visibleRowKeys = next
        return true
    }
}

private struct UnreadMessagesDivider: View {
    var body: some View {
        HStack(spacing: 10) {
            line
            Text("Unread")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tint)
            line
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private var line: some View {
        Rectangle()
            .fill(Color.accentColor.opacity(0.65))
            .frame(height: 1)
    }
}

private struct RowFramePreference: Equatable {
    let key: String
    let frame: CGRect
}

private struct TimelineRowViewportFrame: Equatable {
    let key: String
    let frame: CGRect
}

private struct RowFramesKey: PreferenceKey {
    static let defaultValue: [RowFramePreference] = []
    static func reduce(value: inout [RowFramePreference], nextValue: () -> [RowFramePreference]) {
        value.append(contentsOf: nextValue())
    }
}

private struct TimelineRowViewportFramesKey: PreferenceKey {
    static let defaultValue: [TimelineRowViewportFrame] = []

    static func reduce(
        value: inout [TimelineRowViewportFrame],
        nextValue: () -> [TimelineRowViewportFrame]
    ) {
        value.append(contentsOf: nextValue())
    }
}
