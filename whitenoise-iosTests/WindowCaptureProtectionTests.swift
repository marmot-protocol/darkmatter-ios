import Testing
import UIKit
@testable import whitenoise_ios

/// Behavioral canary for the secure-canvas capture exclusion: the hack rides
/// on private UIKit view/layer structure, so these tests fail loudly on a
/// runtime where that structure changed instead of silently shipping a no-op
/// toggle. The window under test stays off screen with a synthetic superlayer
/// — live-scene layer surgery from a test races the host's own rendering and
/// can crash the whole run.
@MainActor
struct WindowCaptureProtectionTests {
    private func makeDetachedWindow(in superlayer: CALayer) -> UIWindow {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        superlayer.addSublayer(window.layer)
        return window
    }

    @Test func activateExcludesWindowLayerAndDeactivateRestores() {
        let sceneLayer = CALayer()
        let window = makeDetachedWindow(in: sceneLayer)
        let protection = WindowCaptureProtection()

        protection.setActive(true, window: window)

        #expect(protection.isActive)
        #expect(window.layer.superlayer !== sceneLayer)

        protection.setActive(false, window: window)

        #expect(!protection.isActive)
        #expect(window.layer.superlayer === sceneLayer)
    }

    @Test func repeatedTogglesAreIdempotent() {
        let sceneLayer = CALayer()
        let window = makeDetachedWindow(in: sceneLayer)
        let protection = WindowCaptureProtection()

        protection.setActive(true, window: window)
        protection.setActive(true, window: window)
        #expect(protection.isActive)

        protection.setActive(false, window: window)
        protection.setActive(false, window: window)
        #expect(!protection.isActive)
        #expect(window.layer.superlayer === sceneLayer)
    }

    @Test func activationWithoutWindowFailsOpen() {
        let protection = WindowCaptureProtection()

        protection.setActive(true, window: nil)

        #expect(!protection.isActive)
    }
}
