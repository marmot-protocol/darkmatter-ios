import UIKit

/// System capture exclusion for a whole window: while active, screenshots,
/// screen recordings, and app-switcher snapshots render the window blank.
/// There is no public API for this; the window's layer is re-hosted inside a
/// secure text field's canvas layer, which the render server excludes from
/// captures. Window-level on purpose — sheets and full-screen covers present
/// in the same window, so a root-view wrapper would leave them capturable.
///
/// Fails open: when the private layer structure isn't recognized, the window
/// is left untouched and captures stay allowed.
@MainActor
final class WindowCaptureProtection {
    private var field: UITextField?
    private weak var protectedWindow: UIWindow?
    private weak var originalSuperlayer: CALayer?

    var isActive: Bool { field != nil }

    func setActive(_ active: Bool, window: UIWindow?) {
        if active {
            guard let window else { return }
            activate(on: window)
        } else {
            deactivate()
        }
    }

    private func activate(on window: UIWindow) {
        guard field == nil else { return }
        let field = UITextField()
        field.isSecureTextEntry = true
        field.isUserInteractionEnabled = false
        window.addSubview(field)
        field.layoutIfNeeded()
        guard
            let canvasLayer = Self.secureCanvasLayer(of: field),
            let superlayer = window.layer.superlayer
        else {
            field.removeFromSuperview()
            return
        }
        originalSuperlayer = superlayer
        superlayer.addSublayer(field.layer)
        canvasLayer.addSublayer(window.layer)
        self.field = field
        protectedWindow = window
    }

    private func deactivate() {
        guard let field else { return }
        if let window = protectedWindow, let originalSuperlayer {
            // Back at the bottom of the scene's layer stack, where the content
            // window lives beneath sibling windows (e.g. the app-lock shield).
            originalSuperlayer.insertSublayer(window.layer, at: 0)
        }
        field.layer.removeFromSuperlayer()
        field.removeFromSuperview()
        self.field = nil
        protectedWindow = nil
        originalSuperlayer = nil
    }

    private static func secureCanvasLayer(of field: UITextField) -> CALayer? {
        // The capture-excluded canvas is the field's single internal text
        // canvas view; match by class-name suffix with a first-sublayer
        // fallback so a renamed internal view degrades gracefully.
        if let canvasView = field.subviews.first(where: {
            String(describing: type(of: $0)).contains("CanvasView")
        }) {
            return canvasView.layer
        }
        return field.layer.sublayers?.first
    }
}
