import SwiftUI
import UIKit
import MarmotKit
import Contacts
import CoreLocation

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

    static func shouldRepairBottomOverscroll(
        _ viewport: TimelineBottomViewport,
        isUserScrolling: Bool
    ) -> Bool {
        !isUserScrolling && viewport.overscrollPastBottom > overscrollRepairThreshold
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

    static func shouldExecute(
        reason: TimelineBottomScrollReason,
        isUserScrolling: Bool
    ) -> Bool {
        reason.isUserInitiated || !isUserScrolling
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

enum TimelineKeyboardBottomFollow {
    static func distanceToBottom(
        contentHeight: CGFloat,
        boundsHeight: CGFloat,
        adjustedTopInset: CGFloat,
        adjustedBottomInset: CGFloat,
        contentOffsetY: CGFloat
    ) -> CGFloat {
        let bottomOffsetY = ScrollViewBottomClamp.legalBottomOffsetY(
            contentHeight: contentHeight,
            boundsHeight: boundsHeight,
            adjustedTopInset: adjustedTopInset,
            adjustedBottomInset: adjustedBottomInset
        )
        return max(0, bottomOffsetY - contentOffsetY)
    }

    static func shouldBegin(
        distanceToBottom: CGFloat,
        isFollowEnabled: Bool,
        isTracking: Bool,
        isDragging: Bool,
        isDecelerating: Bool
    ) -> Bool {
        isFollowEnabled
            && !isTracking
            && !isDragging
            && !isDecelerating
            && distanceToBottom <= TimelineBottom.pinnedThreshold
    }

    static func shouldClamp(
        contentHeight: CGFloat,
        boundsHeight: CGFloat,
        adjustedTopInset: CGFloat,
        adjustedBottomInset: CGFloat
    ) -> Bool {
        contentHeight + adjustedTopInset + adjustedBottomInset
            > boundsHeight + ScrollViewBottomClamp.tolerance
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
    let isViewModelReady: Bool
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
        let text = viewModel.consumeComposerText(draft) ?? ""
        let attachments = mediaDrafts
        guard !attachments.isEmpty || !text.isEmpty else {
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
    static let minimumVisibleFraction = 0.001
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
        let sanitizedName = ContentSanitizer.groupName(initialTitle)
            ?? ContentSanitizer.groupName(chat.name)
        // A DM (unnamed 2-person) shows just the contact's name — no member
        // count — so don't flash one in the pre-roster initial chrome either.
        // Detect it from the group's own name, not the rendered title: a DM's
        // title hint is the contact's display name, which would otherwise read
        // as a named group. Mirrors `GroupDisplay.isDirectMessage`.
        let isDirectMessage = ContentSanitizer.groupName(chat.name) == nil && initialMemberCount == 2
        return ConversationChromePresentation(
            title: sanitizedName ?? IdentityFormatter.short(chat.groupIdHex),
            subtitle: isDirectMessage ? nil : initialMemberCount.flatMap(memberSubtitle)
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
    case retention(UInt64)
    case subtitle(String?)

    static func resolve(
        isRuntimeWarmingUp: Bool,
        subtitle: String?,
        retentionSeconds: UInt64 = 0
    ) -> ConversationHeaderSecondary {
        if isRuntimeWarmingUp { return .connecting }
        if retentionSeconds > 0 { return .retention(retentionSeconds) }
        return .subtitle(subtitle)
    }
}

/// What the timeline area shows while it holds no rows. The `connecting` state
/// distinguishes local runtime hydration after a background resume from a brief
/// steady-state local read. Relay catch-up continues independently after this
/// state clears.
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

nonisolated enum EmptyGroupConversationPresentation {
    static func canInvite(
        isSelfMember: Bool,
        isSelfAdmin: Bool,
        membersLoaded: Bool,
        memberCount: Int,
        onlyMemberIsSelf: Bool
    ) -> Bool {
        isSelfMember && isSelfAdmin && membersLoaded && memberCount == 1 && onlyMemberIsSelf
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

private struct TimelineKeyboardBottomFollower: UIViewRepresentable {
    let isFollowEnabled: Bool

    func makeUIView(context: Context) -> TimelineKeyboardBottomFollowerView {
        let view = TimelineKeyboardBottomFollowerView()
        view.isFollowEnabled = isFollowEnabled
        return view
    }

    func updateUIView(_ uiView: TimelineKeyboardBottomFollowerView, context: Context) {
        uiView.isFollowEnabled = isFollowEnabled
        uiView.resolveScrollView()
    }

    static func dismantleUIView(
        _ uiView: TimelineKeyboardBottomFollowerView,
        coordinator: Void
    ) {
        uiView.stop()
    }
}

final class TimelineKeyboardBottomFollowerView: UIView {
    var isFollowEnabled = false {
        didSet {
            if !isFollowEnabled {
                stopDisplayLink()
            }
        }
    }

    private weak var resolvedScrollView: UIScrollView?
    private var displayLink: CADisplayLink?
    private var followDeadline: CFTimeInterval = 0
    private var settleFramesRemaining = 0
    private var isObservingKeyboard = false

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        resolveScrollView()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        resolveScrollView()
        if window == nil {
            stop()
        } else {
            startObservingKeyboardIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.resolveScrollView()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        followCurrentFrameIfNeeded()
    }

    func resolveScrollView() {
        resolvedScrollView = enclosingScrollView()
    }

    func stop() {
        stopDisplayLink()
        stopObservingKeyboard()
        resolvedScrollView = nil
    }

    private func startObservingKeyboardIfNeeded() {
        guard !isObservingKeyboard else { return }
        isObservingKeyboard = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardWillChangeFrame(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
    }

    private func stopObservingKeyboard() {
        guard isObservingKeyboard else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        isObservingKeyboard = false
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let scrollView = resolvedScrollView ?? enclosingScrollView() else { return }
        resolvedScrollView = scrollView
        let distanceToBottom = TimelineKeyboardBottomFollow.distanceToBottom(
            contentHeight: scrollView.contentSize.height,
            boundsHeight: scrollView.bounds.height,
            adjustedTopInset: scrollView.adjustedContentInset.top,
            adjustedBottomInset: scrollView.adjustedContentInset.bottom,
            contentOffsetY: scrollView.contentOffset.y
        )
        guard TimelineKeyboardBottomFollow.shouldBegin(
            distanceToBottom: distanceToBottom,
            isFollowEnabled: isFollowEnabled,
            isTracking: scrollView.isTracking,
            isDragging: scrollView.isDragging,
            isDecelerating: scrollView.isDecelerating
        ) else {
            stopDisplayLink()
            return
        }

        let duration = KeyboardFrameChange.animationParameters(from: notification).duration
        followDeadline = CACurrentMediaTime() + max(0.25, duration)
        settleFramesRemaining = 3
        startDisplayLinkIfNeeded()
        followCurrentFrameIfNeeded()
    }

    private func startDisplayLinkIfNeeded() {
        guard displayLink == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
        settleFramesRemaining = 0
    }

    @objc private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        followCurrentFrameIfNeeded()
        guard displayLink.timestamp >= followDeadline else { return }
        if settleFramesRemaining > 0 {
            settleFramesRemaining -= 1
        } else {
            stopDisplayLink()
        }
    }

    private func followCurrentFrameIfNeeded() {
        guard displayLink != nil, isFollowEnabled, let scrollView = resolvedScrollView else { return }
        guard !scrollView.isTracking, !scrollView.isDragging, !scrollView.isDecelerating else {
            stopDisplayLink()
            return
        }
        guard TimelineKeyboardBottomFollow.shouldClamp(
            contentHeight: scrollView.contentSize.height,
            boundsHeight: scrollView.bounds.height,
            adjustedTopInset: scrollView.adjustedContentInset.top,
            adjustedBottomInset: scrollView.adjustedContentInset.bottom
        ) else { return }

        let targetY = ScrollViewBottomClamp.legalBottomOffsetY(
            contentHeight: scrollView.contentSize.height,
            boundsHeight: scrollView.bounds.height,
            adjustedTopInset: scrollView.adjustedContentInset.top,
            adjustedBottomInset: scrollView.adjustedContentInset.bottom
        )
        guard abs(scrollView.contentOffset.y - targetY) > ScrollViewBottomClamp.tolerance else { return }
        UIView.performWithoutAnimation {
            scrollView.setContentOffset(
                CGPoint(x: scrollView.contentOffset.x, y: targetY),
                animated: false
            )
        }
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
    let initialLeaveRequestPending: Bool
    let initialTargetMessageIdHex: String?
    let initialUnreadMessageIdHex: String?
    let forwardDestinationProvider: (() async throws -> [MessageForwardDestination])?
    let onChatListRowUpdated: ((ChatListRowFfi) -> Void)?
    let onGroupChanged: ((AppGroupRecordFfi) -> Void)?
    let onGroupLeft: ((String) -> Void)?
    let onGroupDeleted: ((String) -> Void)?
    let onDraftChanged: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: ConversationViewModel?
    @State private var draft: String = ""
    @State private var mediaDrafts: [MediaDraftAttachment] = []
    @StateObject private var voiceRecorder = VoiceMessageRecorder()
    @State private var showCameraCapture = false
    @State private var showPhotoLibraryPicker = false
    @State private var showMediaApproval = false
    @State private var mediaApprovalDrafts: [MediaDraftAttachment] = []
    @State private var mediaApprovalCaption = ""
    @State private var showFileImporter = false
    @State private var showLocationPicker = false
    @State private var showContactPicker = false
    @State private var showDetails = false
    @State private var openAddMembersOnDetails = false
    @State private var actionsTarget: ActionsTarget?
    @State private var emojiPickerTarget: ActionsTarget?
    @State private var messageInfoTarget: ActionsTarget?
    @State private var reactionDetailsTarget: ReactionDetailsTarget?
    @State private var forwardTarget: ActionsTarget?
    @State private var forwardSelectionTarget: ForwardSelectionTarget?
    @State private var isSelectingMessages = false
    @State private var selectedMessageIds = Set<String>()
    @State private var showBatchDeleteConfirmation = false
    @State private var batchDeleteOperationID: UUID?
    @State private var editSession: ComposerEditSession?
    @State private var editSaveInFlight = false
    @State private var editHistoryTarget: ActionsTarget?
    @State private var deleteTarget: ActionsTarget?
    @State private var failedSendTarget: FailedSendTarget?
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
    @State private var composerDismissRequest = 0
    @State private var isAtTimelineBottom = true
    @State private var isUserScrollingTimeline = false
    @State private var userMovedAwayFromTimelineBottom = false
    @State private var didPerformInitialBottomScroll = false
    @State private var isInitialTimelinePositionSettled = false
    @State private var initialScrollFollowUpTask: Task<Void, Never>?
    @State private var pendingBottomScrollRequest: TimelineBottomScrollRequest?
    @State private var pendingBottomScrollTask: Task<Void, Never>?
    @State private var isOlderTimelineTriggerVisible = false
    @State private var isNewerTimelineTriggerVisible = false
    @State private var lastAutomaticBottomScrollTargetID: String?
    @State private var isInitialBottomStabilizationScheduled = false
    @State private var pendingSearchMatchScrollTask: Task<Void, Never>?
    @State private var replyNavigationTargetItemId: String?
    @State private var replyNavigationTask: Task<Void, Never>?
    @State private var replyNavigationGeneration = 0
    @State private var visibleChatRoute: VisibleChatRoute?
    /// Global Y bounds of the visible timeline (between nav bar and composer).
    /// The bottom shrinks when the keyboard rises, so placement accounts for it.
    @State private var contentTopY: CGFloat = 0
    @State private var contentBottomY: CGFloat = 0

    @ScaledMetric(relativeTo: .caption)
    private var replyCloseIconSize = ReplyPreviewLayout.closeIconSize
    @ScaledMetric(relativeTo: .caption)
    private var replyCloseHitSize = ReplyPreviewLayout.closeHitSize
    @ScaledMetric(relativeTo: .body)
    private var scrollToBottomIconSize: CGFloat = 18
    @ScaledMetric(relativeTo: .body)
    private var scrollToBottomDiameter: CGFloat = 42

    private static let timelineBottomID = "conversation-timeline-bottom"
    private static let actionFrameMeasurementClearDelayNanoseconds: UInt64 = 250_000_000

    private struct ActionsTarget: Identifiable {
        let record: AppMessageRecordFfi
        let status: MessageStatus
        let id = UUID()
    }

    private struct FailedSendTarget: Identifiable {
        let rowId: String
        var id: String { rowId }
    }

    /// Extracted so the conversation body's modifier chain stays within the
    /// Swift type-checker's budget.
    private struct FailedSendDialogModifier: ViewModifier {
        @Binding var target: FailedSendTarget?
        let canRetry: (String) -> Bool
        let canDiscard: (String) -> Bool
        let onRetry: (String) -> Void
        let onDiscard: (String) -> Void

        func body(content: Content) -> some View {
            content.confirmationDialog(
                "Message not sent",
                isPresented: Binding(
                    get: { target != nil },
                    set: { if !$0 { target = nil } }
                ),
                titleVisibility: .visible,
                presenting: target
            ) { target in
                if canRetry(target.rowId) {
                    Button("Try Again") { onRetry(target.rowId) }
                }
                if canDiscard(target.rowId) {
                    Button("Delete", role: .destructive) { onDiscard(target.rowId) }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private struct ReactionDetailsTarget: Identifiable {
        let record: AppMessageRecordFfi
        let initialEmoji: String?
        var messageIdHex: String { record.messageIdHex }
        let id = UUID()
    }

    private struct ForwardSelectionTarget: Identifiable {
        let records: [AppMessageRecordFfi]
        let id = UUID()
    }

    private struct ComposerEditSession {
        let id = UUID()
        let message: AppMessageRecordFfi
        let preservedDraft: String
        let preservedMediaDrafts: [MediaDraftAttachment]
        let preservedMentionState: ComposerMentionDraftState
        let preservedReplyTargetMessageIdHex: String?
    }

    init(
        chat: AppGroupRecordFfi,
        accountRef: String? = nil,
        initialTitle: String? = nil,
        initialOtherMember: String? = nil,
        initialMemberCount: Int? = nil,
        initialLeaveRequestPending: Bool = false,
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
        self.initialLeaveRequestPending = initialLeaveRequestPending
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
                    leaveRequestPending: initialLeaveRequestPending,
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
                !isSelectingMessages
                    && !actionsCentered
                    && actionsTarget?.record.messageIdHex == record.messageIdHex
                    && !record.messageIdHex.isEmpty
            },
            set: { shown in if !shown { dismissActions() } }
        )
    }

    var body: some View {
        timeline
            .trueBlackScaffoldBackground()
            .safeAreaInset(edge: .top, spacing: 0) { searchBarInset }
            .bottomInputChromeAccessory {
                composerArea
                    .frame(maxWidth: .infinity)
                    .background {
                        Color(.systemBackground)
                            .ignoresSafeArea(edges: .bottom)
                    }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .overlay { centeredActionsOverlay }
            // The identity cluster lives leading-aligned next to the back
            // chevron; an inline system title would double it up.
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            // The identity lives in an in-content header instead of a toolbar
            // item: SwiftUI paints custom toolbar content only after the push
            // settles, which blanked the header for ~1s on every entry. In
            // content it is present from the first frame, and the custom back
            // button can resign the keyboard before popping so it no longer
            // flashes mid-screen during the transition.
            .toolbar(.hidden, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) { conversationHeaderBar }
            // An isPresented push fights navigation-path swaps: unwind it
            // before the pending chat replaces the stack, or the details page
            // re-asserts itself over the new conversation.
            .onChange(of: appState.pendingChatId) { _, pending in
                if pending != nil {
                    showDetails = false
                }
            }
            .navigationDestination(isPresented: $showDetails) {
                if let viewModel {
                    GroupDetailsView(
                        viewModel: viewModel,
                        openAddMembersOnAppear: openAddMembersOnDetails,
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
                    .onDisappear { openAddMembersOnDetails = false }
                }
            }
            .sheet(item: $emojiPickerTarget) { target in
                if let viewModel {
                    EmojiPickerSheet(
                        quickReactions: appState.quickReactions,
                        onQuickReactionsSave: appState.setQuickReactions,
                        onQuickReactionsReset: appState.resetQuickReactions,
                        onPick: { emoji in
                            Task { await viewModel.toggleReaction(emoji, on: target.record) }
                            appState.addRecentReaction(emoji)
                        }
                    )
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
                        initialEmoji: target.initialEmoji,
                        onRemoveOwnReaction: { emoji in
                            Task {
                                await viewModel.toggleReaction(emoji, on: target.record)
                                if viewModel.reactions(for: target.messageIdHex).isEmpty {
                                    reactionDetailsTarget = nil
                                }
                            }
                        }
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
            .sheet(item: $forwardSelectionTarget) { target in
                if let viewModel {
                    ForwardMessageSheet(
                        messages: target.records,
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
            .confirmationDialog(
                L10n.plural("Delete %lld selected messages?", Int64(selectedMessageIds.count)),
                isPresented: $showBatchDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button(L10n.string("Delete"), role: .destructive) {
                    deleteSelectedMessages()
                }
                Button(L10n.string("Cancel"), role: .cancel) {}
            }
            .sheet(item: $editHistoryTarget) { target in
                if let viewModel {
                    EditHistorySheet(rows: viewModel.editHistory(for: target.record.messageIdHex))
                        .appAppearance()
                }
            }
            .confirmationDialog(
                "Delete message?",
                isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { if !$0 { deleteTarget = nil } }
                ),
                titleVisibility: .visible,
                presenting: deleteTarget
            ) { target in
                if let viewModel {
                    let capability = viewModel.deleteCapability(for: target.record)
                    if capability.canDeleteForEveryone {
                        Button("Delete for everyone", role: .destructive) {
                            Task { await viewModel.deleteMessageForEveryone(target.record) }
                        }
                    }
                    if capability.canDeleteForMe {
                        Button(
                            capability.canDeleteForEveryone ? "Delete for me" : "Delete",
                            role: .destructive
                        ) {
                            Task { _ = await viewModel.deleteMessageForMe(target.record) }
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .modifier(FailedSendDialogModifier(
                target: $failedSendTarget,
                canRetry: { viewModel?.canRetryFailedSend(rowId: $0) ?? false },
                canDiscard: { viewModel?.canDiscardFailedSend(rowId: $0) ?? false },
                onRetry: { rowId in Task { await viewModel?.retryFailedSend(rowId: rowId) } },
                onDiscard: { viewModel?.discardFailedSend(rowId: $0) }
            ))
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
            .fullScreenCover(isPresented: $showMediaApproval) {
                MediaApprovalView(
                    attachments: $mediaApprovalDrafts,
                    caption: $mediaApprovalCaption,
                    reservedAttachmentCount: mediaDrafts.count,
                    isSending: viewModel?.sendInFlight ?? false,
                    onAddSelections: addMediaApprovalSelections,
                    onSelectionError: { error in
                        appState.present(.error(
                            L10n.string("Couldn't add attachment"),
                            message: error.localizedDescription
                        ))
                    },
                    onCancel: dismissMediaApproval,
                    onSend: sendApprovedMedia
                )
                .appAppearance()
            }
            .sheet(isPresented: $showLocationPicker) {
                LocationPickerView(
                    onSend: { coordinate in
                        showLocationPicker = false
                        sendSharedLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                    },
                    onCancel: { showLocationPicker = false }
                )
                .appAppearance()
            }
            .sheet(isPresented: $showContactPicker) {
                ContactCardPicker(
                    onPick: { contact in
                        showContactPicker = false
                        addContactCard(contact)
                    },
                    onCancel: { showContactPicker = false }
                )
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
                        leaveRequestPending: initialLeaveRequestPending,
                        onChatListRowUpdated: onChatListRowUpdated
                    )
                }
                await viewModel?.start()
            }
            .task(id: ConversationDraftLoadToken(
                accountRef: draftAccountRef,
                groupIdHex: chat.groupIdHex,
                isViewModelReady: viewModel != nil
            )) {
                await restorePersistedDraft()
            }
            .onChange(of: appState.streamingDebugEnabled) { _, _ in
                viewModel?.refreshStreamingDebugPresentation()
            }
            .onChange(of: appState.profileRefreshGeneration) { _, _ in
                viewModel?.refreshProfileDependentTimelineProjections()
            }
            .onChange(of: appState.retentionSweepGeneration) { _, _ in
                guard appState.retentionSweepPrunedGroupIds.contains(chat.groupIdHex) else { return }
                Task { await viewModel?.refreshTimelineWindowAfterLocalPrune() }
            }
            .onReceive(NotificationCenter.default.publisher(for: AppLanguage.didChangeNotification)) { _ in
                viewModel?.refreshProfileDependentTimelineProjections()
            }
            .onChange(of: viewModel?.canSendMessages ?? true) { _, canSendMessages in
                handleComposerAvailabilityChange(canSendMessages: canSendMessages)
            }
            .onChange(of: draft) { _, draft in
                if editSession == nil {
                    persistCurrentDraft(text: draft)
                }
            }
            .onChange(of: mediaDrafts.map(\.id)) { _, _ in
                if editSession == nil {
                    persistCurrentDraft()
                }
            }
            .onChange(of: viewModel?.replyTargetMessageIdHex) { _, _ in
                if editSession == nil {
                    persistCurrentDraft()
                }
            }
            .onAppear {
                visibleChatRoute = appState.beginViewingChat(groupIdHex: chat.groupIdHex)
            }
            .onDisappear {
                if let visibleChatRoute {
                    appState.endViewingChat(visibleChatRoute)
                }
                voiceRecorder.cancelIfActive()
                viewModel?.search.end()
                cancelPendingTimelineFollowUpWork()
                dismissKeyboard()
                if let editSession {
                    persistDraft(
                        editSession.preservedMentionState,
                        mediaAttachments: editSession.preservedMediaDrafts,
                        replyToMessageIdHex: editSession.preservedReplyTargetMessageIdHex
                    )
                } else {
                    persistCurrentDraft()
                }
                onDraftChanged?()
                exitMessageSelection()
                Task { await appState.conversationDraftStore.flush() }
            }
    }

    // MARK: - Composer + reply

    @ViewBuilder
    private var composerArea: some View {
        if isSelectingMessages, let viewModel {
            messageSelectionBar(viewModel: viewModel)
        } else if let viewModel, viewModel.hasPendingInvite {
            inviteResponseArea(viewModel: viewModel)
        } else {
            VStack(spacing: 0) {
                if let viewModel, let editSession {
                    editBar(for: editSession, viewModel: viewModel)
                } else if let viewModel,
                          let replyTargetMessageIdHex = viewModel.replyTargetMessageIdHex
                {
                    replyBar(
                        for: viewModel.replyingTo ?? viewModel.record(for: replyTargetMessageIdHex),
                        viewModel: viewModel
                    )
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
                    isSending: (viewModel?.sendInFlight ?? false) || editSaveInFlight,
                    hasAttachments: !mediaDrafts.isEmpty,
                    audioDraft: inlineAudioDraft,
                    mediaEnabled: editSession == nil && (viewModel?.canSendMediaAttachments ?? false),
                    disabledMessage: viewModel?.inactiveGroupMessage,
                    voiceRecordingActive: voiceRecorder.isActive,
                    focusRequest: composerFocusRequest,
                    dismissRequest: composerDismissRequest,
                    mentionCandidates: mentionCandidates,
                    submissionEnabled: editSubmissionEnabled,
                    submissionAccessibilityLabel: editSession == nil
                        ? L10n.string("Send")
                        : L10n.string("Save edit"),
                    voiceMessagesEnabled: editSession == nil,
                    onTakePhoto: takePhoto,
                    onPhotoLibrary: openPhotoLibrary,
                    onAttachFile: openFileImporter,
                    onShareLocation: openLocationPicker,
                    onShareContact: openContactPicker,
                    onPasteImage: pasteImage,
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
        }
    }

    private func messageSelectionBar(viewModel: ConversationViewModel) -> some View {
        let records = selectedMessageRecords(viewModel: viewModel)
        let canForward = MessageSelectionPolicy.canForward(
            selectedCount: records.count,
            allForwardable: records.allSatisfy { MessageForwardingPolicy.forwardableText(for: $0) != nil }
        )
        let canDelete = MessageSelectionPolicy.canDelete(
            selectedCount: records.count,
            allDeletable: records.allSatisfy {
                // Same per-message rules as the single-message menu: admins
                // can delete others' messages, members only their own.
                viewModel.deleteCapability(for: $0).canDeleteForEveryone
                    && !viewModel.isDeleted($0.messageIdHex)
            }
        )

        let bodies = records.map { viewModel.displayBody(of: $0) }
        let canCopy = MessageSelectionPolicy.canCopy(
            selectedCount: records.count,
            anyHasText: bodies.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        )

        return HStack(spacing: 0) {
            Button(role: .destructive) {
                guard canDelete else { return }
                showBatchDeleteConfirmation = true
            } label: {
                if batchDeleteInFlight {
                    ProgressView().frame(width: 44, height: 44)
                } else {
                    Image(systemName: "trash")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(canDelete && !batchDeleteInFlight ? Color.red : Color.secondary.opacity(0.4))
            .disabled(!canDelete || batchDeleteInFlight)
            .accessibilityLabel(L10n.string("Delete selected messages"))

            Spacer(minLength: 0)

            Text(L10n.plural("%lld selected", Int64(records.count)))
                .font(.subheadline.weight(.semibold))

            Spacer(minLength: 0)

            Button {
                guard canCopy else { return }
                SensitiveClipboard.copyLocalOnly(MessageSelectionPolicy.combinedCopyText(bodies))
                Haptics.tap()
                exitMessageSelection()
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canCopy ? Color.accentColor : Color.secondary.opacity(0.4))
            .disabled(!canCopy)
            .accessibilityLabel(L10n.string("Copy selected messages"))

            Button {
                guard canForward else { return }
                forwardSelectionTarget = ForwardSelectionTarget(records: records)
                exitMessageSelection()
            } label: {
                Image(systemName: "arrowshape.turn.up.right")
                    .font(.title3)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(canForward ? Color.accentColor : Color.secondary.opacity(0.4))
            .disabled(!canForward)
            .accessibilityLabel(L10n.string("Forward selected messages"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
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

    private func replyBar(
        for record: AppMessageRecordFfi?,
        viewModel: ConversationViewModel
    ) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor)
                .frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                if let record {
                    Text(L10n.formatted(
                        "Replying to %@",
                        appState.displayName(forAccountIdHex: record.sender)
                    ))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .shadow(color: .black.opacity(0.28), radius: 1.5, y: 1)
                    Text(ContentSanitizer.compactSingleLine(
                        viewModel.displayBody(of: record),
                        maxLength: 100
                    ) ?? "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .shadow(color: .black.opacity(0.22), radius: 1, y: 1)
                } else {
                    Text(L10n.string("Reply"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .shadow(color: .black.opacity(0.28), radius: 1.5, y: 1)
                }
            }
            Spacer()
            Button {
                viewModel.restoreReplyTarget(messageIdHex: nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: replyCloseIconSize, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(
                        width: replyCloseHitSize,
                        height: replyCloseHitSize,
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

    private func editBar(for session: ComposerEditSession, viewModel: ConversationViewModel) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.string("Editing message"))
                    .font(.caption.weight(.semibold))
                Text(ContentSanitizer.compactSingleLine(viewModel.displayBody(of: session.message), maxLength: 100) ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: cancelEdit) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: replyCloseIconSize, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: replyCloseHitSize, height: replyCloseHitSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("Cancel edit"))
        }
        .padding(.leading, ReplyPreviewLayout.leadingContentInset)
        .padding(.trailing, ReplyPreviewLayout.closeTrailingInset)
        .padding(.vertical, ReplyPreviewLayout.contentTopInset)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
        .padding(.horizontal, ReplyPreviewLayout.outerHorizontalInset)
        .padding(.top, ReplyPreviewLayout.outerTopInset)
        .padding(.bottom, ReplyPreviewLayout.outerBottomInset)
    }

    /// Leading identity cluster: avatar beside the back chevron, then the
    /// name over the member count or disappearing-message duration. Tapping it
    /// is the single way into the details page for
    /// both direct messages and groups.
    private var conversationHeaderBar: some View {
        HStack(spacing: 8) {
            Button {
                // Resign the composer before popping so the keyboard animates
                // down first instead of flashing mid-screen during the pop.
                dismissKeyboard()
                dismiss()
            } label: {
                Image(systemName: "chevron.backward")
                    .font(.body.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.string("Back"))

            conversationTitle

            Spacer(minLength: 0)

            if isSelectingMessages {
                Button(L10n.string("Cancel")) { exitMessageSelection() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            LinearGradient(
                stops: [
                    .init(color: Color(.systemBackground), location: 0),
                    .init(color: Color(.systemBackground).opacity(0.94), location: 0.58),
                    .init(color: Color(.systemBackground).opacity(0.68), location: 0.82),
                    .init(color: Color(.systemBackground).opacity(0), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea(edges: .top)
        }
    }

    @ViewBuilder
    private var conversationTitle: some View {
        let chrome = conversationChrome
        Button {
            // The destination renders only once the model exists; a tap in
            // the load window would push an empty page. Selection mode keeps
            // the title visible but inert — the count lives in the action bar.
            guard viewModel != nil, !isSelectingMessages else { return }
            // Resign the composer before pushing so the keyboard animates
            // down first instead of flashing mid-screen during the push.
            dismissKeyboard()
            showDetails = true
        } label: {
            HStack(spacing: 10) {
                if let viewModel {
                    let groupDisplay = viewModel.groupDisplay
                    GroupAvatarBubble(
                        groupIdHex: viewModel.group.groupIdHex,
                        imageHashHex: viewModel.group.pendingConfirmation ? nil : viewModel.group.imageHashHex,
                        seed: GroupDisplay.avatarSeed(for: groupDisplay),
                        title: chrome.title,
                        pictureURL: viewModel.group.imageHashHex != nil
                            && ContentSanitizer.imageURL(viewModel.group.avatarUrl) == nil
                            ? nil
                            : GroupDisplay.avatarURL(for: groupDisplay, appState: appState)
                    )
                    .frame(width: 34, height: 34)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(chrome.title)
                        .font(.headline)
                        .lineLimit(1)
                    conversationHeaderSecondary(
                        subtitle: chrome.subtitle,
                        retentionSeconds: viewModel?.group.disappearingMessageSecs ?? chat.disappearingMessageSecs
                    )
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(isSelectingMessages ? "" : L10n.string("Shows conversation details"))
    }

    @ViewBuilder
    private func conversationHeaderSecondary(subtitle: String?, retentionSeconds: UInt64) -> some View {
        switch ConversationHeaderSecondary.resolve(
            isRuntimeWarmingUp: appState.isRuntimeWarmingUp,
            subtitle: subtitle,
            retentionSeconds: retentionSeconds
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
        case .retention(let seconds):
            HStack(spacing: 4) {
                Image(systemName: "timer")
                Text(GroupRetentionPresentation.label(seconds: seconds))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.formatted(
                "Disappearing messages: %@",
                GroupRetentionPresentation.label(seconds: seconds)
            ))
        case .subtitle(let value):
            // No placeholder line when there is no subtitle (direct messages):
            // reserving the space pushes the name off vertical center.
            if let value {
                Text(value)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
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
                    .contentShape(.rect)
                    .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
            } else if viewModel.timeline.isEmpty {
                emptyTimeline(viewModel: viewModel)
            } else {
                let concealInitialTimeline = shouldConcealInitialTimelineContent(viewModel: viewModel)
                ScrollViewReader { proxy in
                    GeometryReader { outer in
                        ScrollView {
                            VStack(spacing: 0) {
                                LazyVStack(alignment: .leading, spacing: 4, pinnedViews: [.sectionHeaders]) {
                                    olderTimelineTrigger(viewModel: viewModel)
                                    ForEach(viewModel.timelineDaySections()) { section in
                                        Section {
                                            ForEach(section.items) { item in
                                                if TimelineUnreadDivider.shouldShow(
                                                    before: item,
                                                    firstUnreadMessageIdHex: initialUnreadMessageIdHex
                                                ) {
                                                    UnreadMessagesDivider()
                                                        .id(unreadDividerID(for: initialUnreadMessageIdHex ?? ""))
                                                }
                                                row(for: item, viewModel: viewModel)
                                                    .background {
                                                        searchMatchHighlight(for: item, viewModel: viewModel)
                                                    }
                                                    .onScrollVisibilityChange(
                                                        threshold: TimelineViewportVisibility.minimumVisibleFraction
                                                    ) { isVisible in
                                                        if timelineVisibility.set(
                                                            item.rowFrameKey,
                                                            isVisible: isVisible
                                                        ), isVisible {
                                                            markCurrentlyVisibleMessagesRead(viewModel: viewModel)
                                                        }
                                                    }
                                            }
                                        } header: {
                                            timelineDateHeader(section)
                                        }
                                    }
                                    .padding(.bottom, 4)
                                    newerTimelineTrigger(viewModel: viewModel)
                                }
                                timelineBottomSentinel
                            }
                            .padding(.top, 8)
                            .padding(.bottom, BottomInputChromeLayout.timelineComposerSpacing)
                            .background {
                                InitialBottomScrollClamp(
                                    isEnabled: isInitialBottomPositioning(viewModel: viewModel)
                                )
                                .frame(width: 0, height: 0)
                            }
                            .background {
                                TimelineKeyboardDismissInstaller(onTap: dismissKeyboard)
                                    .frame(width: 0, height: 0)
                            }
                            .background {
                                TimelineKeyboardBottomFollower(
                                    isFollowEnabled: !userMovedAwayFromTimelineBottom
                                        && !isUserScrollingTimeline
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
                        .defaultScrollAnchor(.bottom)
                        .defaultScrollAnchor(.bottom, for: .sizeChanges)
                        // Only scroll/bounce when the messages actually exceed
                        // the viewport; with a few messages the timeline stays
                        // put instead of rubber-banding under the pinned day
                        // header.
                        .scrollBounceBehavior(.basedOnSize)
                        .compatibleBottomScrollEdgeEffectHidden()
                        .scrollDismissesKeyboard(.interactively)
                        .onScrollPhaseChange { _, phase in
                            isUserScrollingTimeline = phase == .interacting || phase == .decelerating
                            if isUserScrollingTimeline {
                                cancelPendingBottomScroll()
                            }
                            if phase == .idle, isAtTimelineBottom {
                                userMovedAwayFromTimelineBottom = false
                            }
                        }
                        .onPreferenceChange(RowFramesKey.self) { rowFrames.replace(with: $0) }
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
                            } else if TimelineBottom.shouldRepairBottomOverscroll(
                                current,
                                isUserScrolling: isUserScrollingTimeline
                            ) {
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
                                if current.isPinned {
                                    userMovedAwayFromTimelineBottom = false
                                } else if isUserScrollingTimeline {
                                    userMovedAwayFromTimelineBottom = true
                                }
                            }
                        }
                        .onChange(of: viewModel.timeline.last?.id) { _, newId in
                            guard newId != nil else { return }
                            if performInitialScrollIfNeeded(proxy: proxy, viewModel: viewModel) {
                                return
                            }
                            settleInitialTimelinePositionIfNoScrollNeeded(viewModel: viewModel)
                            if !userMovedAwayFromTimelineBottom {
                                isAtTimelineBottom = true
                                scheduleScrollToBottom(
                                    proxy: proxy,
                                    animated: true,
                                    reason: .timelineChange,
                                    targetID: newId
                                )
                            }
                        }
                        .onChange(of: viewModel.timelineProjectionGeneration) { _, _ in
                            viewModel.search.refreshAfterTimelineChange()
                            pruneMessageSelection(viewModel: viewModel)
                            handleTimelineProjectionChange(proxy: proxy, viewModel: viewModel)
                        }
                        .onChange(of: viewModel.search.scrollRequest) { _, request in
                            guard let request else { return }
                            scheduleSearchMatchScroll(to: request.itemId, proxy: proxy)
                        }
                        .onChange(of: replyNavigationTargetItemId) { _, itemId in
                            guard let itemId else { return }
                            isAtTimelineBottom = false
                            userMovedAwayFromTimelineBottom = true
                            scheduleSearchMatchScroll(to: itemId, proxy: proxy)
                            replyNavigationTargetItemId = nil
                        }
                        .onChange(of: outer.size.height) { _, _ in
                            contentTopY = outer.frame(in: .global).minY
                            contentBottomY = outer.frame(in: .global).maxY
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
                            cancelPendingSearchMatchScroll()
                        }
                    }
                }
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func emptyTimeline(viewModel: ConversationViewModel) -> some View {
        Group {
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
            case .empty:
                if viewModel.canInviteFromEmptyGroup {
                    ContentUnavailableView {
                        Label("Only you are here", systemImage: "person.2")
                    } description: {
                        Text("Add members to start the conversation.")
                    } actions: {
                        Button {
                            dismissKeyboard()
                            openAddMembersOnDetails = true
                            showDetails = true
                        } label: {
                            Label("Add members", systemImage: "person.badge.plus")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                } else {
                    ContentUnavailableView(
                        "No messages yet",
                        systemImage: "bubble.middle.bottom",
                        description: Text("Send the first message to get started.")
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(.rect)
        .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
    }

    private func timelineDateHeader(_ section: TimelineDaySection) -> some View {
        Text(ConversationDateHeader.label(timestamp: UInt64(max(0, section.day.timeIntervalSince1970))))
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay {
                Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func row(for item: TimelineItem, viewModel: ConversationViewModel) -> some View {
        switch item.kind {
        case .message(let record, let status):
            if let groupSystemText = viewModel.groupSystemDisplayText(for: record) {
                GroupSystemEventRow(text: groupSystemText)
                    .id(item.id)
            } else if let agentDisplay = viewModel.agentEventDisplay(for: item) {
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
                    record: record,
                    initialEmoji: emoji
                )
            },
            onReplyPreviewTap: {
                guard let targetId = viewModel.replyTargetMessageId(for: record) else { return }
                navigateToReplyTarget(targetId, viewModel: viewModel)
            },
            onLoadMedia: ConversationMediaLoader { media in
                try await viewModel.data(for: media)
            },
            onViewEditHistory: viewModel.hasEditHistory(record.messageIdHex)
                ? { editHistoryTarget = ActionsTarget(record: record, status: status) }
                : nil,
            onFailedTap: status == .failed
                ? { failedSendTarget = FailedSendTarget(rowId: item.id) }
                : nil
        )
        .replySwipeToReply(
            isEnabled: !isSelectingMessages && allowsActions && canReply(to: record, viewModel: viewModel)
        ) {
            beginReply(to: record, viewModel: viewModel)
        }
        .padding(.leading, isSelectingMessages ? 36 : 0)
        .overlay {
            if isSelectingMessages {
                let selected = selectedMessageIds.contains(record.messageIdHex)
                ZStack(alignment: .leading) {
                    Color.clear
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.55))
                        .padding(.leading, 8)
                }
                .contentShape(.rect)
                .onTapGesture { toggleMessageSelection(record.messageIdHex) }
                .accessibilityElement()
                .accessibilityLabel(
                    selected
                        ? L10n.string("Deselect message")
                        : L10n.string("Select message")
                )
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
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
            guard !isSelectingMessages,
                  allowsActions,
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
        if userMovedAwayFromTimelineBottom || viewModel.hasMoreAfter {
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
                    .font(.system(size: scrollToBottomIconSize, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: scrollToBottomDiameter, height: scrollToBottomDiameter)
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
        userMovedAwayFromTimelineBottom = false
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
        guard TimelineBottomScrollCoordinator.shouldExecute(
            reason: reason,
            isUserScrolling: isUserScrollingTimeline
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
            guard TimelineBottomScrollCoordinator.shouldExecute(
                reason: request.reason,
                isUserScrolling: isUserScrollingTimeline
            ) else { return }
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
            isPinned: !userMovedAwayFromTimelineBottom,
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
        viewModel.markVisibleMessagesRead(
            viewModel.records(forRowFrameKeys: visibleRowKeys)
        )
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
        cancelEdit()
        viewModel.replyingTo = record
        composerFocusRequest += 1
    }

    private func beginEdit(_ message: AppMessageRecordFfi, viewModel: ConversationViewModel) {
        guard MessageEditingPolicy.canEdit(
            message,
            isDeleted: viewModel.isDeleted(message.messageIdHex),
            canSendMessages: viewModel.canSendMessages
        ) else { return }
        let preservedDraft = editSession?.preservedDraft ?? draft
        let preservedMediaDrafts = editSession?.preservedMediaDrafts ?? mediaDrafts
        let preservedMentionState = editSession?.preservedMentionState
            ?? viewModel.composerMentionDraftState(for: preservedDraft)
        let preservedReplyTargetMessageIdHex = editSession?.preservedReplyTargetMessageIdHex
            ?? viewModel.replyTargetMessageIdHex
        viewModel.replyingTo = nil
        mediaDrafts.removeAll()
        cancelVoiceRecording()
        editSession = ComposerEditSession(
            message: message,
            preservedDraft: preservedDraft,
            preservedMediaDrafts: preservedMediaDrafts,
            preservedMentionState: preservedMentionState,
            preservedReplyTargetMessageIdHex: preservedReplyTargetMessageIdHex
        )
        draft = viewModel.editingText(for: message)
        composerFocusRequest += 1
    }

    private var editSubmissionEnabled: Bool {
        guard let editSession, let viewModel,
              let outgoing = viewModel.preparedComposerText(draft)
        else { return editSession == nil }
        return outgoing != editSession.message.plaintext
    }

    private var batchDeleteInFlight: Bool {
        batchDeleteOperationID != nil
    }

    private func cancelEdit() {
        guard let editSession else { return }
        self.editSession = nil
        viewModel?.restoreComposerMentionDraftState(editSession.preservedMentionState)
        viewModel?.restoreReplyTarget(messageIdHex: editSession.preservedReplyTargetMessageIdHex)
        draft = editSession.preservedDraft
        mediaDrafts = editSession.preservedMediaDrafts
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
        if let editSession, editSubmissionEnabled, let viewModel {
            let editedContent = draft
            editSaveInFlight = true
            Task {
                defer { editSaveInFlight = false }
                guard await viewModel.editMessage(editSession.message, content: editedContent) else { return }
                guard self.editSession?.id == editSession.id else { return }
                self.editSession = nil
                viewModel.restoreComposerMentionDraftState(editSession.preservedMentionState)
                viewModel.restoreReplyTarget(messageIdHex: editSession.preservedReplyTargetMessageIdHex)
                draft = editSession.preservedDraft
                mediaDrafts = editSession.preservedMediaDrafts
            }
            return
        }
        guard let payload = ConversationSendPreparation.prepare(
            draft: &draft,
            mediaDrafts: &mediaDrafts,
            viewModel: viewModel
        ) else { return }
        Task {
            if payload.attachments.isEmpty {
                await payload.viewModel.sendPreparedComposerText(payload.text)
            } else {
                await payload.viewModel.sendPreparedMedia(payload.attachments, caption: payload.text)
            }
        }
    }

    private func handleComposerAvailabilityChange(canSendMessages: Bool) {
        guard !canSendMessages else { return }
        draft = ""
        editSession = nil
        viewModel?.replyingTo = nil
        cancelVoiceRecording()
        showCameraCapture = false
        showPhotoLibraryPicker = false
        showMediaApproval = false
        mediaApprovalDrafts.removeAll()
        mediaApprovalCaption = ""
        showFileImporter = false
        showLocationPicker = false
        showContactPicker = false
        dismissKeyboard()
    }

    private func restorePersistedDraft() async {
        guard let draftAccountRef, let viewModel else { return }
        let draftBeforeLoad = draft
        let mediaIDsBeforeLoad = mediaDrafts.map(\.id)
        let replyBeforeLoad = viewModel.replyTargetMessageIdHex
        guard let snapshot = await appState.conversationDraftStore.snapshot(
            accountRef: draftAccountRef,
            groupIdHex: chat.groupIdHex
        ) else {
            guard !Task.isCancelled,
                  draft == draftBeforeLoad,
                  mediaDrafts.map(\.id) == mediaIDsBeforeLoad,
                  viewModel.replyTargetMessageIdHex == replyBeforeLoad
            else { return }
            draft = ""
            mediaDrafts.removeAll()
            viewModel.restoreReplyTarget(messageIdHex: nil)
            return
        }
        guard !Task.isCancelled,
              draft == draftBeforeLoad,
              mediaDrafts.map(\.id) == mediaIDsBeforeLoad,
              viewModel.replyTargetMessageIdHex == replyBeforeLoad
        else { return }
        let mentionState = ComposerMentionDraftState(
            canonicalText: snapshot.canonicalText,
            mentionDisplayName: { appState.mentionDisplayName(for: $0) }
        )
        viewModel.restoreComposerMentionDraftState(mentionState)
        viewModel.restoreReplyTarget(messageIdHex: snapshot.replyToMessageIdHex)
        mediaDrafts = snapshot.mediaAttachments
        draft = mentionState.draft
    }

    private func persistCurrentDraft(text: String? = nil) {
        let text = text ?? draft
        let mentionState = viewModel?.composerMentionDraftState(for: text)
            ?? ComposerMentionDraftState(draft: text, selectedMentions: [])
        persistDraft(
            mentionState,
            mediaAttachments: mediaDrafts,
            replyToMessageIdHex: viewModel?.replyTargetMessageIdHex
        )
    }

    private func persistDraft(
        _ mentionState: ComposerMentionDraftState,
        mediaAttachments: [MediaDraftAttachment],
        replyToMessageIdHex: String?
    ) {
        guard let draftAccountRef else { return }
        appState.conversationDraftStore.setDraft(
            ConversationDraftSnapshot(
                canonicalText: mentionState.canonicalText,
                replyToMessageIdHex: replyToMessageIdHex,
                mediaAttachments: mediaAttachments
            ),
            accountRef: draftAccountRef,
            groupIdHex: chat.groupIdHex
        )
    }

    private func takePhoto() {
        guard editSession == nil else { return }
        guard canBeginMediaSelection() else { return }
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            appState.present(.warning(L10n.string("Camera is not available on this device")))
            return
        }
        showCameraCapture = true
    }

    private func openPhotoLibrary() {
        guard editSession == nil else { return }
        guard canBeginMediaSelection() else { return }
        showPhotoLibraryPicker = true
    }

    private func openFileImporter() {
        guard editSession == nil else { return }
        guard canBeginMediaSelection() else { return }
        showFileImporter = true
    }

    private func openLocationPicker() {
        guard editSession == nil else { return }
        guard viewModel?.canSendMessages == true else { return }
        showLocationPicker = true
    }

    private func openContactPicker() {
        guard editSession == nil else { return }
        guard canBeginMediaSelection() else { return }
        showContactPicker = true
    }

    private func pasteImage(_ image: UIImage) {
        guard editSession == nil else { return }
        guard canBeginMediaSelection() else { return }
        addCameraImage(image)
    }

    private func sendSharedLocation(latitude: Double, longitude: Double) {
        guard let viewModel, viewModel.canSendMessages else { return }
        let text = SharedLocationText.value(latitude: latitude, longitude: longitude)
        Task { await viewModel.sendPreparedComposerText(ConversationViewModel.cappedOutgoingText(text)) }
    }

    private func addContactCard(_ contact: CNContact) {
        Task { @MainActor in
            do {
                let data = try ContactCardExport.data(for: contact)
                let attachment = try await MediaDraftProcessor.preparedAttachment(
                    from: data,
                    fileName: ContactCardExport.fileName(for: contact),
                    typeIdentifier: "public.vcard"
                )
                try appendMediaDraft(attachment)
            } catch is CancellationError {
                return
            } catch {
                appState.present(.error(L10n.string("Couldn't add contact"), message: error.localizedDescription))
            }
        }
    }

    private func addCameraImage(_ image: UIImage) {
        Task { @MainActor in
            do {
                let attachment = try await MediaDraftProcessor.preparedAttachment(from: image, fileName: nil)
                presentMediaApproval([attachment])
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
            var prepared: [MediaDraftAttachment] = []
            for selection in selected {
                do {
                    let attachment = try await MediaDraftProcessor.preparedAttachment(
                        from: selection.data,
                        fileName: selection.fileName,
                        typeIdentifier: selection.typeIdentifier
                    )
                    prepared.append(attachment)
                } catch is CancellationError {
                    return
                } catch {
                    appState.present(.error(L10n.string("Couldn't add attachment"), message: error.localizedDescription))
                }
            }
            guard !prepared.isEmpty else { return }
            presentMediaApproval(prepared)
        }
    }

    private func presentMediaApproval(_ attachments: [MediaDraftAttachment]) {
        guard !attachments.isEmpty else { return }
        mediaApprovalDrafts = attachments
        mediaApprovalCaption = draft
        showMediaApproval = true
    }

    private func addMediaApprovalSelections(_ selections: [PhotoLibrarySelection]) {
        let availableSlots = max(
            0,
            MediaDraftProcessor.maxAttachmentCount - mediaDrafts.count - mediaApprovalDrafts.count
        )
        guard availableSlots > 0 else {
            presentMaxAttachmentWarning()
            return
        }
        let selected = Array(selections.prefix(availableSlots))
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
                    mediaApprovalDrafts.append(attachment)
                } catch is CancellationError {
                    return
                } catch {
                    appState.present(.error(L10n.string("Couldn't add attachment"), message: error.localizedDescription))
                }
            }
        }
    }

    private func dismissMediaApproval() {
        showMediaApproval = false
        mediaApprovalDrafts.removeAll()
        mediaApprovalCaption = ""
    }

    private func sendApprovedMedia() {
        guard let viewModel,
              viewModel.canSendMessages,
              !viewModel.sendInFlight,
              !mediaApprovalDrafts.isEmpty
        else { return }
        let attachments = mediaApprovalDrafts
        let caption = viewModel.consumeComposerText(mediaApprovalCaption) ?? ""
        draft = ""
        dismissMediaApproval()
        Task {
            await viewModel.sendPreparedMedia(attachments, caption: caption)
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
        composerDismissRequest &+= 1
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
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
        replyNavigationGeneration &+= 1
        replyNavigationTask?.cancel()
        replyNavigationTask = nil
        cancelPendingBottomScroll()
        cancelPendingSearchMatchScroll()
        cancelActionFrameMeasurement()
    }

    private func navigateToReplyTarget(_ messageIdHex: String, viewModel: ConversationViewModel) {
        replyNavigationTask?.cancel()
        replyNavigationGeneration &+= 1
        let generation = replyNavigationGeneration
        replyNavigationTask = Task { @MainActor in
            defer {
                if replyNavigationGeneration == generation {
                    replyNavigationTask = nil
                }
            }

            if viewModel.record(for: messageIdHex) != nil {
                replyNavigationTargetItemId = "msg:\(messageIdHex)"
                return
            }

            for _ in 0..<12 where viewModel.hasMoreBefore {
                guard !Task.isCancelled else { return }
                let previousOldestId = viewModel.timeline.first?.id
                await viewModel.loadOlderTimelinePage()
                guard !Task.isCancelled else { return }

                if viewModel.record(for: messageIdHex) != nil {
                    replyNavigationTargetItemId = "msg:\(messageIdHex)"
                    return
                }
                guard viewModel.timeline.first?.id != previousOldestId else { break }
            }

            appState.present(.warning(L10n.string("Original message is no longer available")))
        }
    }

    // MARK: - In-conversation search

    @ViewBuilder
    private var searchBarInset: some View {
        if let viewModel, viewModel.search.isActive {
            ConversationSearchBar(
                search: viewModel.search,
                onClose: { closeSearch() }
            )
        }
    }

    private func closeSearch() {
        cancelPendingSearchMatchScroll()
        viewModel?.search.end()
    }

    @ViewBuilder
    private func searchMatchHighlight(for item: TimelineItem, viewModel: ConversationViewModel) -> some View {
        if viewModel.search.isActive, viewModel.search.currentMatch?.itemId == item.id {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(0.16))
        }
    }

    /// Jump the timeline to a search match. Deferred through a cancellable
    /// main-actor task like the bottom-follow coordinator, and any queued
    /// bottom-follow is cancelled so it cannot race the targeted jump.
    private func scheduleSearchMatchScroll(to itemId: String, proxy: ScrollViewProxy) {
        cancelPendingBottomScroll()
        pendingSearchMatchScrollTask?.cancel()
        pendingSearchMatchScrollTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            pendingSearchMatchScrollTask = nil
            isAtTimelineBottom = false
            withAnimation(.smooth(duration: 0.2)) {
                proxy.scrollTo(itemId, anchor: .center)
            }
        }
    }

    private func cancelPendingSearchMatchScroll() {
        pendingSearchMatchScrollTask?.cancel()
        pendingSearchMatchScrollTask = nil
    }

    // MARK: - Message selection

    private func selectedMessageRecords(viewModel: ConversationViewModel) -> [AppMessageRecordFfi] {
        viewModel.timeline.compactMap { item in
            guard case .message(let record, _) = item.kind,
                  selectedMessageIds.contains(record.messageIdHex)
            else { return nil }
            return record
        }
    }

    private func beginMessageSelection(with record: AppMessageRecordFfi) {
        guard !record.messageIdHex.isEmpty else { return }
        cancelEdit()
        viewModel?.replyingTo = nil
        dismissKeyboard()
        isSelectingMessages = true
        selectedMessageIds = [record.messageIdHex]
        Haptics.tap()
    }

    private func toggleMessageSelection(_ messageIdHex: String) {
        guard isSelectingMessages, !messageIdHex.isEmpty else { return }
        if selectedMessageIds.contains(messageIdHex) {
            selectedMessageIds.remove(messageIdHex)
        } else {
            selectedMessageIds.insert(messageIdHex)
        }
        Haptics.tap()
    }

    private func exitMessageSelection() {
        batchDeleteOperationID = nil
        isSelectingMessages = false
        selectedMessageIds.removeAll()
        showBatchDeleteConfirmation = false
    }

    private func pruneMessageSelection(viewModel: ConversationViewModel) {
        guard isSelectingMessages else { return }
        let availableIds = Set(viewModel.timeline.compactMap { item -> String? in
            guard case .message(let record, _) = item.kind else { return nil }
            return record.messageIdHex
        })
        selectedMessageIds.formIntersection(availableIds)
    }

    private func deleteSelectedMessages() {
        guard let viewModel, !batchDeleteInFlight else { return }
        let records = selectedMessageRecords(viewModel: viewModel)
        guard MessageSelectionPolicy.canDelete(
            selectedCount: records.count,
            allDeletable: records.allSatisfy {
                // Must stay in lockstep with the selection bar's gate — a
                // divergence turns an enabled Delete into a silent no-op.
                viewModel.deleteCapability(for: $0).canDeleteForEveryone
                    && !viewModel.isDeleted($0.messageIdHex)
            }
        ) else { return }

        let operationID = UUID()
        batchDeleteOperationID = operationID
        Task { @MainActor in
            for record in records {
                guard !Task.isCancelled else { break }
                _ = await viewModel.deleteMessageForEveryone(record)
            }
            guard batchDeleteOperationID == operationID else { return }
            batchDeleteOperationID = nil
            exitMessageSelection()
        }
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
            canInteract: viewModel.canSendMessages,
            canForward: MessageForwardingPolicy.forwardableText(for: record) != nil,
            canEdit: MessageEditingPolicy.canEdit(
                record,
                isDeleted: viewModel.isDeleted(record.messageIdHex),
                canSendMessages: viewModel.canSendMessages
            ),
            canViewEditHistory: viewModel.hasEditHistory(record.messageIdHex),
            canDelete: viewModel.deleteCapability(for: record).canDelete,
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
                SensitiveClipboard.copyLocalOnly(viewModel.displayBody(of: record))
                Haptics.tap()
                dismissActions()
            },
            onForward: {
                let target = ActionsTarget(record: record, status: status)
                dismissActions()
                forwardTarget = target
            },
            onEdit: {
                dismissActions()
                beginEdit(record, viewModel: viewModel)
            },
            onViewEditHistory: {
                let target = ActionsTarget(record: record, status: status)
                dismissActions()
                editHistoryTarget = target
            },
            onInfo: {
                let target = ActionsTarget(record: record, status: status)
                dismissActions()
                messageInfoTarget = target
            },
            onSelect: {
                dismissActions()
                beginMessageSelection(with: record)
            },
            onDelete: {
                let target = ActionsTarget(record: record, status: status)
                dismissActions()
                deleteTarget = target
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

/// Tracks only visibility edge changes so scrolling does not publish every
/// row's frame through SwiftUI preferences on each display refresh.
final class TimelineVisibilityStore {
    private(set) var visibleRowKeys: Set<String> = []

    @discardableResult
    func set(_ rowKey: String, isVisible: Bool) -> Bool {
        if isVisible {
            return visibleRowKeys.insert(rowKey).inserted
        }
        return visibleRowKeys.remove(rowKey) != nil
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

private struct RowFramesKey: PreferenceKey {
    static let defaultValue: [RowFramePreference] = []
    static func reduce(value: inout [RowFramePreference], nextValue: () -> [RowFramePreference]) {
        value.append(contentsOf: nextValue())
    }
}

@MainActor
final class TimelineKeyboardDismissController: NSObject, UIGestureRecognizerDelegate {
    var onTap: () -> Void
    private(set) weak var installedScrollView: UIScrollView?

    lazy var recognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(handleRecognizedTap)
        )
        recognizer.cancelsTouchesInView = false
        recognizer.delaysTouchesBegan = false
        recognizer.delaysTouchesEnded = false
        recognizer.delegate = self
        return recognizer
    }()

    init(onTap: @escaping () -> Void) {
        self.onTap = onTap
    }

    func install(on scrollView: UIScrollView?) {
        guard installedScrollView !== scrollView else { return }
        installedScrollView?.removeGestureRecognizer(recognizer)
        installedScrollView = scrollView
        scrollView?.addGestureRecognizer(recognizer)
    }

    func uninstall() {
        install(on: nil)
    }

    @objc func handleRecognizedTap() {
        onTap()
    }

    func gestureRecognizer(
        _: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        !Self.isCompetingTimelineGesture(otherGestureRecognizer)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === recognizer
            && Self.isCompetingTimelineGesture(otherGestureRecognizer)
    }

    private static func isCompetingTimelineGesture(_ recognizer: UIGestureRecognizer) -> Bool {
        recognizer is UIPanGestureRecognizer || recognizer is UILongPressGestureRecognizer
    }
}

private struct TimelineKeyboardDismissInstaller: UIViewRepresentable {
    let onTap: () -> Void

    func makeCoordinator() -> TimelineKeyboardDismissController {
        TimelineKeyboardDismissController(onTap: onTap)
    }

    func makeUIView(context: Context) -> TimelineKeyboardDismissAttachmentView {
        let view = TimelineKeyboardDismissAttachmentView()
        view.controller = context.coordinator
        return view
    }

    func updateUIView(_ uiView: TimelineKeyboardDismissAttachmentView, context: Context) {
        context.coordinator.onTap = onTap
        uiView.controller = context.coordinator
        uiView.resolveScrollView()
    }

    static func dismantleUIView(
        _ uiView: TimelineKeyboardDismissAttachmentView,
        coordinator: TimelineKeyboardDismissController
    ) {
        uiView.controller = nil
        coordinator.uninstall()
    }
}

final class TimelineKeyboardDismissAttachmentView: UIView {
    weak var controller: TimelineKeyboardDismissController?

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        resolveScrollView()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        resolveScrollView()
        DispatchQueue.main.async { [weak self] in
            self?.resolveScrollView()
        }
    }

    func resolveScrollView() {
        controller?.install(on: enclosingScrollView())
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
