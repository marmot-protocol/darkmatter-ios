import SwiftUI

@main
struct darkmatter_iosApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .task {
                    await appState.bootstrap()
                }
                .onOpenURL { url in
                    appState.handle(url: url)
                }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await appState.catchUpAfterForegroundActivation() }
                }
        }
    }
}
