import SwiftUI

struct ChatNotificationsView: View {
    @Environment(AppState.self) private var appState
    @Bindable var model: GroupDetailsViewModel

    var body: some View {
        Form {
            Section {
                Picker(selection: Binding(
                    get: { model.notifyMode },
                    set: { model.setNotifyMode($0, using: appState) }
                )) {
                    Text("All messages").tag(ChatNotifyMode.all)
                    Text("Only mentions").tag(ChatNotifyMode.mentionsOnly)
                    Text("Nothing").tag(ChatNotifyMode.nothing)
                } label: {
                    Text("Notify me about")
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } footer: {
                Text("Applies on this device only. Messages still arrive and count as unread. With \"Only mentions\", this chat notifies only when someone mentions you.")
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
    }
}
