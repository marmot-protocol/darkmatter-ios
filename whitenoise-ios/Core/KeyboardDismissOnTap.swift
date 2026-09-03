import SwiftUI
import UIKit

@MainActor
enum KeyboardDismissTap {
    /// A tap inside a text input must not resign it, or tapping from one field
    /// straight into another would close the keyboard instead of moving focus.
    static func resignsKeyboard(touching view: UIView?) -> Bool {
        var candidate = view
        while let current = candidate {
            if current is UITextField || current is UITextView { return false }
            candidate = current.superview
        }
        return true
    }
}

private final class KeyboardDismissProbeView: UIView {
    var onWindowChange: ((UIWindow?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(window)
    }
}

private struct KeyboardDismissOnTap: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UIView {
        let probe = KeyboardDismissProbeView()
        probe.isUserInteractionEnabled = false
        let coordinator = context.coordinator
        probe.onWindowChange = { window in
            MainActor.assumeIsolated { coordinator.attach(to: window) }
        }
        return probe
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.attach(to: nil)
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var window: UIWindow?

        private lazy var recognizer: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
            // Taps still reach rows, menus, and buttons underneath.
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            return recognizer
        }()

        func attach(to window: UIWindow?) {
            guard window !== self.window else { return }
            self.window?.removeGestureRecognizer(recognizer)
            self.window = window
            window?.addGestureRecognizer(recognizer)
        }

        @objc private func dismissKeyboard() {
            window?.endEditing(true)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            KeyboardDismissTap.resignsKeyboard(touching: touch.view)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }
}

extension View {
    func dismissesKeyboardOnTap() -> some View {
        background(KeyboardDismissOnTap())
    }
}
