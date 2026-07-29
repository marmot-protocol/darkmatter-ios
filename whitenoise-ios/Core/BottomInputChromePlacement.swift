import SwiftUI

extension View {
    /// Pins bottom input chrome while allowing keyboard-height accessory panels
    /// to resize the content viewport without turning a system bar into a
    /// dynamically expanding container.
    @ViewBuilder
    func bottomInputChromeAccessory<Accessory: View>(
        @ViewBuilder accessory: @escaping () -> Accessory
    ) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            accessory()
        }
    }
}
