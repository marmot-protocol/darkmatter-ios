import SwiftUI

/// The app's switch tint: monochrome app chrome rather than the blue system
/// accent. Shared so one switch looks the same wherever it is offered — a
/// setting and the shortcut to it must not disagree.
private struct WNToggleTint: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.tint(colorScheme == .dark ? Color(uiColor: .systemGray) : .black)
    }
}

extension View {
    func wnToggleTint() -> some View {
        modifier(WNToggleTint())
    }
}
