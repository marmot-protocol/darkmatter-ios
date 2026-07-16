import SwiftUI
import UIKit

@MainActor
enum KeyboardFrameChange {
    static func isVisible(from notification: Notification) -> Bool {
        guard
            let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
            let screenBounds
        else { return false }

        return frame.minY < screenBounds.maxY && frame.maxY > screenBounds.minY
    }

    static func bottomGap(from notification: Notification) -> CGFloat {
        isVisible(from: notification) ? BottomInputChromeLayout.keyboardInset : 0
    }

    static func accessoryPanelHeight(from notification: Notification) -> CGFloat? {
        guard
            let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
            let screenBounds
        else { return nil }

        let visibleHeight = screenBounds.intersection(frame).height
        guard visibleHeight > 0 else { return nil }
        return max(0, visibleHeight - foregroundWindowSafeAreaBottom)
    }

    static func shouldUpdateBottomGap(current: CGFloat, next: CGFloat) -> Bool {
        abs(current - next) > 0.5
    }

    static func shouldUpdateVisibility(current: Bool, next: Bool) -> Bool {
        current != next
    }

    static func animation(from notification: Notification) -> Animation {
        guard
            let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
        else { return .easeOut(duration: 0.25) }
        return .easeOut(duration: duration)
    }

    private static var screenBounds: CGRect? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first(where: { $0.activationState == .foregroundActive })?.screen.bounds
            ?? scenes.first(where: { $0.activationState == .foregroundInactive })?.screen.bounds
            ?? scenes.first?.screen.bounds
    }

    private static var foregroundWindowSafeAreaBottom: CGFloat {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first(where: { $0.activationState == .foregroundInactive })
            ?? scenes.first
        let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
        return window?.safeAreaInsets.bottom ?? 0
    }
}
