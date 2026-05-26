import SwiftUI

extension View {
    /// Uses iOS 26 Liquid Glass when available, with a material fallback for
    /// the iOS 18 support floor.
    @ViewBuilder
    func compatibleGlassEffect(
        cornerRadius: CGFloat,
        fallbackMaterial: Material = .regularMaterial
    ) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(
                fallbackMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
    }
}
