import SwiftUI

/// Per-chat notification settings. Mute is the control that exists today;
/// delivery modes join it when the engine surfaces them.
struct ChatNotificationsView: View {
    @Environment(AppState.self) private var appState
    @Bindable var model: GroupDetailsViewModel

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Mute",
                    isOn: Binding(
                        get: { model.isMuted },
                        set: { model.setMuted($0, using: appState) }
                    )
                )
            } footer: {
                Text("Muting silences this chat's notification banners and sounds on this device. Messages still arrive and count as unread.")
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}
