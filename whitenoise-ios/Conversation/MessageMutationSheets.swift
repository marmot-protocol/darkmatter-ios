import SwiftUI
import MarmotKit

struct ForwardMessageSheet: View {
    @Environment(\.dismiss) private var dismiss

    let messages: [AppMessageRecordFfi]
    let viewModel: ConversationViewModel
    let destinationProvider: () async throws -> [MessageForwardDestination]

    @State private var destinations: [MessageForwardDestination] = []
    @State private var selectedGroupIds = Set<String>()
    @State private var isLoading = true
    @State private var isSending = false
    @State private var loadFailed = false
    @State private var sendFailed = false

    init(
        message: AppMessageRecordFfi,
        viewModel: ConversationViewModel,
        destinationProvider: @escaping () async throws -> [MessageForwardDestination]
    ) {
        self.messages = [message]
        self.viewModel = viewModel
        self.destinationProvider = destinationProvider
    }

    init(
        messages: [AppMessageRecordFfi],
        viewModel: ConversationViewModel,
        destinationProvider: @escaping () async throws -> [MessageForwardDestination]
    ) {
        self.messages = Array(messages.prefix(MessageSelectionPolicy.maximumForwardCount))
        self.viewModel = viewModel
        self.destinationProvider = destinationProvider
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            forwardButton
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSending)
        .task { await loadDestinations() }
    }

    private var header: some View {
        ZStack {
            Text(messages.count == 1 ? L10n.string("Forward") : L10n.formatted("Forward %lld messages", Int64(messages.count)))
                .font(.headline)

            HStack {
                Button("Cancel") { dismiss() }
                    .disabled(isSending)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loadFailed {
            ContentUnavailableView {
                Label("Couldn't load chats", systemImage: "exclamationmark.triangle")
            } actions: {
                Button("Retry") {
                    Task { await loadDestinations() }
                }
            }
        } else if destinations.isEmpty {
            ContentUnavailableView("No chats yet", systemImage: "bubble.left.and.bubble.right")
        } else {
            List(destinations) { destination in
                Button {
                    toggle(destination.id)
                } label: {
                    HStack(spacing: 12) {
                        AvatarBubble(
                            seed: destination.id,
                            title: destination.title,
                            pictureURL: destination.avatarURL
                        )
                        .frame(width: 42, height: 42)

                        Text(destination.title)
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                        Spacer(minLength: 8)

                        Image(systemName: selectedGroupIds.contains(destination.id)
                              ? "checkmark.circle.fill"
                              : "circle")
                            .font(.title3)
                            .foregroundStyle(selectedGroupIds.contains(destination.id) ? Color.accentColor : .secondary)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedGroupIds.contains(destination.id) ? .isSelected : [])
            }
            .listStyle(.plain)
        }
    }

    private var forwardButton: some View {
        VStack(spacing: 8) {
            if sendFailed {
                Text("Send failed")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }

            Button {
                Task { await forward() }
            } label: {
                Group {
                    if isSending {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text("Forward")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 24)
            }
            .buttonStyle(.borderedProminent)
            .disabled(selectedGroupIds.isEmpty || isSending || isLoading)
        }
        .padding(16)
    }

    private func toggle(_ groupIdHex: String) {
        sendFailed = false
        if selectedGroupIds.contains(groupIdHex) {
            selectedGroupIds.remove(groupIdHex)
        } else {
            selectedGroupIds.insert(groupIdHex)
        }
    }

    private func loadDestinations() async {
        isLoading = true
        loadFailed = false
        defer { isLoading = false }
        do {
            destinations = try await destinationProvider()
        } catch {
            loadFailed = true
        }
    }

    private func forward() async {
        guard !selectedGroupIds.isEmpty else { return }
        isSending = true
        sendFailed = false
        let result = await viewModel.forwardMessages(messages, to: selectedGroupIds)
        isSending = false
        if result.succeededCompletely {
            dismiss()
        } else {
            // Successful destinations are removed so Retry cannot duplicate
            // them; only failed sends remain selected.
            selectedGroupIds = result.failedGroupIds
            sendFailed = true
        }
    }
}

struct EditMessageSheet: View {
    @Environment(\.dismiss) private var dismiss

    let message: AppMessageRecordFfi
    let viewModel: ConversationViewModel

    @State private var draft: String
    @State private var isSaving = false
    @FocusState private var editorFocused: Bool

    init(message: AppMessageRecordFfi, viewModel: ConversationViewModel) {
        self.message = message
        self.viewModel = viewModel
        _draft = State(initialValue: message.plaintext)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            TextEditor(text: $draft)
                .focused($editorFocused)
                .padding(12)
                .scrollContentBackground(.hidden)
                .background(Color(.secondarySystemBackground))
                .clipShape(.rect(cornerRadius: 12))
                .padding(16)
                .onChange(of: draft) { _, value in
                    if value.count > ContentSanitizer.maxMessageLength {
                        draft = String(value.prefix(ContentSanitizer.maxMessageLength))
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSaving)
        .onAppear { editorFocused = true }
    }

    private var header: some View {
        ZStack {
            Text("Edit")
                .font(.headline)

            HStack {
                Button("Cancel") { dismiss() }
                    .disabled(isSaving)
                Spacer()
                Button("Save") {
                    Task { await save() }
                }
                .fontWeight(.semibold)
                .disabled(!canSave)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
    }

    private var canSave: Bool {
        guard !isSaving,
              let normalized = MessageEditingPolicy.normalizedContent(draft)
        else { return false }
        return normalized != message.plaintext
    }

    private func save() async {
        guard canSave else { return }
        isSaving = true
        let succeeded = await viewModel.editMessage(message, content: draft)
        isSaving = false
        if succeeded {
            dismiss()
        }
    }
}
