import SwiftUI

/// Presents a chat from inside nested presentation stacks. The chat-list
/// coordinator owns the dismissal-aware retry loop, so publish the intent
/// immediately instead of stacking another fixed delay in front of it.
@MainActor
enum DeferredChatPresentation {
    static func present(
        groupIdHex: String,
        messageIdHex: String? = nil,
        using appState: AppState,
        dismissFirst dismiss: DismissAction? = nil
    ) {
        dismiss?()
        HostActionPerformance.groupNavigationRequested(groupIdHex: groupIdHex)
        appState.presentChat(groupIdHex: groupIdHex, messageIdHex: messageIdHex)
    }
}
