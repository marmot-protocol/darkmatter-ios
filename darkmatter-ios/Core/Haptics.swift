import UIKit

/// Tiny helper around `UIImpactFeedbackGenerator` / `UINotificationFeedbackGenerator`.
/// Wraps the iOS feedback APIs so view code can just say `Haptics.tap()`
/// without managing generator lifecycle.
enum Haptics {

    @MainActor
    static func tap(intensity: CGFloat = 1.0) {
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.prepare()
        gen.impactOccurred(intensity: intensity)
    }

    @MainActor
    static func selection() {
        let gen = UISelectionFeedbackGenerator()
        gen.prepare()
        gen.selectionChanged()
    }

    @MainActor
    static func success() {
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        gen.notificationOccurred(.success)
    }

    @MainActor
    static func warning() {
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        gen.notificationOccurred(.warning)
    }

    @MainActor
    static func error() {
        let gen = UINotificationFeedbackGenerator()
        gen.prepare()
        gen.notificationOccurred(.error)
    }
}
