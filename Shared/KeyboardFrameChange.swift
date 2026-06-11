import CoreGraphics
import SwiftUI
import UIKit

enum KeyboardFrameChange {
    static func isVisible(from notification: Notification) -> Bool {
        guard
            let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        else { return false }

        let screenHeight = UIScreen.main.bounds.height
        return frame.origin.y < screenHeight
    }

    static func bottomGap(from notification: Notification) -> CGFloat {
        isVisible(from: notification) ? BottomInputChromeLayout.keyboardInset : 0
    }

    static func animation(from notification: Notification) -> Animation {
        guard
            let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
        else { return .easeOut(duration: 0.25) }
        return .easeOut(duration: duration)
    }
}
