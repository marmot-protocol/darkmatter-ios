import SwiftUI

/// Presents a chat from inside nested presentation stacks. Dismissing a
/// sheet and swapping the navigation path in the same tick makes SwiftUI
/// roll the path change back, stranding the user on the previous chat — so
/// the pending-chat intent is posted only after the dismissal has settled.
@MainActor
enum DeferredChatPresentation {
    static let settleDelayNanoseconds: UInt64 = 450_000_000

    static func present(
        groupIdHex: String,
        messageIdHex: String? = nil,
        using appState: AppState,
        dismissFirst dismiss: DismissAction? = nil
    ) {
        dismiss?()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: settleDelayNanoseconds)
            appState.presentChat(groupIdHex: groupIdHex, messageIdHex: messageIdHex)
        }
    }
}
