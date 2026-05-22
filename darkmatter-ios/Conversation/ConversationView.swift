import SwiftUI
import UIKit
import MarmotKit

struct ConversationView: View {
    @Environment(AppState.self) private var appState
    let chat: AppGroupRecordFfi

    @State private var viewModel: ConversationViewModel?
    @State private var draft: String = ""
    @State private var showDetails = false
    @State private var actionsTarget: ActionsTarget?
    @State private var emojiPickerTarget: ActionsTarget?
    /// When the long-pressed bubble sits too low for the actions popover to fit
    /// below it, flip the popover above the bubble instead.
    @State private var actionsAbove = false
    /// When a bubble is so tall that neither above nor below has room, drop the
    /// popover and show the menu as a centered overlay over the bubble instead.
    @State private var actionsCentered = false
    @State private var rowFrames = RowFrameStore()
    /// Global Y bounds of the visible timeline (between nav bar and composer).
    /// The bottom shrinks when the keyboard rises, so placement accounts for it.
    @State private var contentTopY: CGFloat = 0
    @State private var contentBottomY: CGFloat = 0

    private struct ActionsTarget: Identifiable {
        let record: AppMessageRecordFfi
        let id = UUID()
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
            .safeAreaInset(edge: .bottom) { composerArea }
            .overlay { centeredActionsOverlay }
            .navigationTitle(viewModel?.displayTitle ?? chat.name)
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
                        GroupDetailsView(viewModel: viewModel)
                    }
                }
            }
            .sheet(item: $emojiPickerTarget) { target in
                if let viewModel {
                    EmojiPickerSheet(onPick: { emoji in
                        Task { await viewModel.toggleReaction(emoji, on: target.record) }
                        appState.addRecentReaction(emoji)
                    })
                }
            }
            .task {
                if viewModel == nil {
                    viewModel = ConversationViewModel(appState: appState, group: chat)
                }
                await viewModel?.start()
            }
    }

    // MARK: - Composer + reply

    @ViewBuilder
    private var composerArea: some View {
        VStack(spacing: 0) {
            if let viewModel, let replyingTo = viewModel.replyingTo {
                replyBar(for: replyingTo, viewModel: viewModel)
            }
            ComposerBar(
                draft: $draft,
                isSending: viewModel?.sendInFlight ?? false,
                onSend: send
            )
        }
        .background(alignment: .bottom) { composerBackdrop }
    }

    /// Blur behind the composer + reply box that mirrors the nav bar's
    /// scroll-edge effect at the top: the toolbar `.bar` material, fading out
    /// as it rises, extended ~40pt above the composer.
    private var composerBackdrop: some View {
        Rectangle()
            .fill(.bar)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.65),
                        .init(color: .black, location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .padding(.top, -40)
            .ignoresSafeArea(edges: .bottom)
            .allowsHitTesting(false)
    }

    private func replyBar(for record: AppMessageRecordFfi, viewModel: ConversationViewModel) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor)
                .frame(width: 3, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Replying to \(appState.displayName(forAccountIdHex: record.sender))")
                    .font(.caption.weight(.semibold))
                Text(ProfileSanitizer.singleLine(viewModel.displayBody(of: record), maxLength: 100) ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                viewModel.replyingTo = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    @ViewBuilder
    private var conversationTitle: some View {
        if let viewModel {
            VStack(spacing: 0) {
                Text(viewModel.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                Text(viewModel.displaySubtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else {
            Text(chat.name)
                .font(.headline)
        }
    }

    // MARK: - Timeline

    @ViewBuilder
    private var timeline: some View {
        if let viewModel {
            if viewModel.timeline.isEmpty {
                ContentUnavailableView(
                    "No messages yet",
                    systemImage: "bubble.middle.bottom",
                    description: Text("Send the first message to get started.")
                )
            } else {
                ScrollViewReader { proxy in
                    GeometryReader { outer in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 4) {
                                ForEach(viewModel.timeline) { item in
                                    row(for: item, viewModel: viewModel)
                                }
                            }
                            .padding(.vertical, 8)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
                        .onPreferenceChange(RowFramesKey.self) { rowFrames.frames = $0 }
                        .onChange(of: viewModel.timeline.last?.id) { _, newId in
                            guard let newId else { return }
                            withAnimation(.smooth(duration: 0.2)) {
                                proxy.scrollTo(newId, anchor: .bottom)
                            }
                        }
                        .onChange(of: outer.size.height) { _, _ in
                            contentTopY = outer.frame(in: .global).minY
                            contentBottomY = outer.frame(in: .global).maxY
                        }
                        .onAppear {
                            contentTopY = outer.frame(in: .global).minY
                            contentBottomY = outer.frame(in: .global).maxY
                            if let last = viewModel.timeline.last?.id {
                                proxy.scrollTo(last, anchor: .bottom)
                            }
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
            MessageBubble(
                record: record,
                status: status,
                isDeleted: viewModel.isDeleted(record.messageIdHex),
                replyPreview: viewModel.replyPreview(for: record),
                reactions: viewModel.reactions(for: record.messageIdHex),
                onTapReaction: { emoji in
                    Task { await viewModel.toggleReaction(emoji, on: record) }
                    appState.addRecentReaction(emoji)
                }
            )
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: RowFramesKey.self,
                        value: [record.messageIdHex: geo.frame(in: .global)]
                    )
                }
            )
            .id(item.id)
            .onLongPressGesture {
                guard !record.messageIdHex.isEmpty,
                      !viewModel.isDeleted(record.messageIdHex) else { return }
                Haptics.tap()
                presentActions(for: record)
            }
            .gesture(replySwipe(for: record, viewModel: viewModel))
            .popover(
                isPresented: actionsBinding(for: record),
                attachmentAnchor: .point(actionsAbove ? .top : .bottom),
                arrowEdge: actionsAbove ? .bottom : .top
            ) {
                actionsMenu(for: record, viewModel: viewModel)
            }
        case .systemEvent(let event):
            SystemEventRow(event: event)
                .id(item.id)
        }
    }

    /// Lightweight swipe-right-to-reply. Fires only on release for a clearly
    /// horizontal drag, so it doesn't fight the scroll view.
    private func replySwipe(for record: AppMessageRecordFfi, viewModel: ConversationViewModel) -> some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                if value.translation.width > 60,
                   abs(value.translation.width) > abs(value.translation.height) {
                    Haptics.tap()
                    viewModel.replyingTo = record
                }
            }
    }

    private func send() {
        let text = draft
        draft = ""
        Task {
            await viewModel?.send(text)
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil
        )
    }

    // MARK: - Message actions placement

    /// Decide where the actions menu opens for the long-pressed bubble: below it
    /// (default), flipped above it (no room below), or centered over it (the
    /// bubble is so tall neither end has room — a popover would land off-screen).
    private func presentActions(for record: AppMessageRecordFfi) {
        let frame = rowFrames.frames[record.messageIdHex]
        let spaceBelow = contentBottomY - (frame?.maxY ?? 0)
        let spaceAbove = (frame?.minY ?? 0) - contentTopY
        let fitsBelow = spaceBelow >= Self.actionsMenuEstimate
        let fitsAbove = spaceAbove >= Self.actionsMenuEstimate

        actionsAbove = !fitsBelow
        if !fitsBelow && !fitsAbove {
            withAnimation(.easeOut(duration: 0.15)) {
                actionsCentered = true
                actionsTarget = ActionsTarget(record: record)
            }
        } else {
            actionsCentered = false
            actionsTarget = ActionsTarget(record: record)
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
                actionsMenu(for: target.record, viewModel: viewModel)
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
        viewModel: ConversationViewModel
    ) -> some View {
        MessageActionsMenu(
            isMine: record.direction == "sent",
            quickReactions: appState.quickReactions,
            onReact: { emoji in
                Task { await viewModel.toggleReaction(emoji, on: record) }
                appState.addRecentReaction(emoji)
                dismissActions()
            },
            onReply: {
                viewModel.replyingTo = record
                dismissActions()
            },
            onCopy: {
                UIPasteboard.general.string = viewModel.displayBody(of: record)
                Haptics.tap()
                dismissActions()
            },
            onDelete: {
                Task { await viewModel.deleteMessage(record) }
                dismissActions()
            },
            onMoreEmoji: {
                let target = record
                dismissActions()
                emojiPickerTarget = ActionsTarget(record: target)
            }
        )
    }

    /// Approximate height of the actions popover (reaction row + action rows +
    /// arrow). If neither end of the bubble has at least this much room, the
    /// menu is centered over the bubble instead of anchored to it.
    private static let actionsMenuEstimate: CGFloat = 280
}

/// Holds the latest on-screen frame of each message row. A reference type so
/// scroll-driven updates don't churn SwiftUI state; we only read it on demand
/// when a long press needs to decide which way the actions popover should open.
private final class RowFrameStore {
    var frames: [String: CGRect] = [:]
}

private struct RowFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}
