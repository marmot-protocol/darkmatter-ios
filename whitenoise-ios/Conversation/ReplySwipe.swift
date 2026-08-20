import SwiftUI
import UIKit

enum ReplySwipe {
    static let minimumDistance: CGFloat = 24
    static let activationThreshold: CGFloat = 60
    static let maximumFeedbackOffset: CGFloat = 32
    static let completionOffset: CGFloat = 12
    static let completionAnimationDuration: TimeInterval = 0.045
    static let resetAnimationDuration: TimeInterval = 0.08
    static let completionPauseNanoseconds: UInt64 = 18_000_000

    private static let horizontalDominance: CGFloat = 1.2

    static func shouldBegin(velocity: CGPoint) -> Bool {
        velocity.x > 0
            && velocity.x > abs(velocity.y) * horizontalDominance
    }

    static func shouldActivate(translation: CGSize) -> Bool {
        translation.width > activationThreshold
            && isRightwardHorizontal(translation)
    }

    static func feedbackOffset(translation: CGSize) -> CGFloat {
        guard translation.width >= minimumDistance,
              isRightwardHorizontal(translation)
        else { return 0 }
        return min(maximumFeedbackOffset, translation.width * 0.42)
    }

    private static func isRightwardHorizontal(_ translation: CGSize) -> Bool {
        translation.width > 0
            && translation.width > abs(translation.height) * horizontalDominance
    }
}

extension View {
    func replySwipeToReply(isEnabled: Bool, onReply: @escaping () -> Void) -> some View {
        modifier(ReplySwipeModifier(isEnabled: isEnabled, onReply: onReply))
    }
}

private struct ReplySwipeModifier: ViewModifier {
    let isEnabled: Bool
    let onReply: () -> Void

    @State private var offset: CGFloat = 0
    @State private var resetTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        if isEnabled {
            ZStack(alignment: .leading) {
                if offset > 0 {
                    Image(systemName: "arrowshape.turn.up.left.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: ReplySwipe.maximumFeedbackOffset)
                        .opacity(min(1, offset / ReplySwipe.maximumFeedbackOffset))
                        .scaleEffect(offset >= ReplySwipe.maximumFeedbackOffset ? 1 : 0.82)
                        .accessibilityHidden(true)
                }

                content
                    .offset(x: offset)
            }
                .contentShape(.rect)
                .gesture(
                    ReplySwipePanGesture(
                        onChanged: handleSwipeChange,
                        onEnded: handleSwipeEnd,
                        onCancelled: resetReplySwipe
                    )
                )
                .onDisappear { resetTask?.cancel() }
        } else {
            content
        }
    }

    private func handleSwipeChange(_ translation: CGSize) {
        let nextOffset = ReplySwipe.feedbackOffset(translation: translation)
        guard nextOffset > 0 || offset > 0 else { return }
        resetTask?.cancel()
        offset = nextOffset
    }

    private func handleSwipeEnd(_ translation: CGSize) {
        if ReplySwipe.shouldActivate(translation: translation) {
            completeReplySwipe()
        } else {
            resetReplySwipe()
        }
    }

    private func completeReplySwipe() {
        resetTask?.cancel()
        Haptics.tap()
        withAnimation(.snappy(duration: ReplySwipe.completionAnimationDuration, extraBounce: 0)) {
            offset = ReplySwipe.completionOffset
        }
        resetTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: ReplySwipe.completionPauseNanoseconds)
            } catch {
                return
            }
            withAnimation(.snappy(duration: ReplySwipe.resetAnimationDuration, extraBounce: 0)) {
                offset = 0
            }
            onReply()
            resetTask = nil
        }
    }

    private func resetReplySwipe() {
        resetTask?.cancel()
        withAnimation(.snappy(duration: ReplySwipe.resetAnimationDuration, extraBounce: 0)) {
            offset = 0
        }
        resetTask = nil
    }
}

private struct ReplySwipePanGesture: UIGestureRecognizerRepresentable {
    let onChanged: (CGSize) -> Void
    let onEnded: (CGSize) -> Void
    let onCancelled: () -> Void

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var gesture: ReplySwipePanGesture

        init(gesture: ReplySwipePanGesture) {
            self.gesture = gesture
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let panGesture = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            return ReplySwipe.shouldBegin(velocity: panGesture.velocity(in: panGesture.view))
        }

        func gestureRecognizer(
            _: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    func makeCoordinator(converter _: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(gesture: self)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let gesture = UIPanGestureRecognizer()
        gesture.cancelsTouchesInView = false
        gesture.maximumNumberOfTouches = 1
        gesture.delegate = context.coordinator
        return gesture
    }

    func updateUIGestureRecognizer(_: UIPanGestureRecognizer, context: Context) {
        context.coordinator.gesture = self
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let translation = recognizer.translation(in: recognizer.view)
        let size = CGSize(width: translation.x, height: translation.y)
        switch recognizer.state {
        case .began, .changed:
            context.coordinator.gesture.onChanged(size)
        case .ended:
            context.coordinator.gesture.onEnded(size)
        case .cancelled, .failed:
            context.coordinator.gesture.onCancelled()
        case .possible:
            break
        @unknown default:
            context.coordinator.gesture.onCancelled()
        }
    }
}
