import SwiftUI

// navigationTitle takes a plain String, so the title is a one-time snapshot:
// the view body only re-resolves it if it reads the locale environment, which
// these settings screens do not. Snapshot the title and recompute it whenever
// the screen appears or the in-app language changes.
struct LocalizedNavigationTitleState {
    private let resolve: () -> String
    private(set) var title: String

    init(resolve: @escaping () -> String) {
        self.resolve = resolve
        self.title = resolve()
    }

    mutating func refresh() {
        title = resolve()
    }
}

private struct LocalizedNavigationTitleModifier: ViewModifier {
    @State private var state: LocalizedNavigationTitleState

    init(_ key: String.LocalizationValue) {
        _state = State(initialValue: LocalizedNavigationTitleState(resolve: { L10n.string(key) }))
    }

    func body(content: Content) -> some View {
        content
            .navigationTitle(state.title)
            .onAppear { state.refresh() }
            .onReceive(NotificationCenter.default.publisher(for: AppLanguage.didChangeNotification)) { _ in
                state.refresh()
            }
    }
}

extension View {
    func localizedNavigationTitle(_ key: String.LocalizationValue) -> some View {
        modifier(LocalizedNavigationTitleModifier(key))
    }
}
