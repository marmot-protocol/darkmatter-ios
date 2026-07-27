import SwiftUI

nonisolated enum WhiteNoiseSupportContact {
    static let npub = "npub1zymqqmvktw8lkr5dp6zzw5xk3fkdqcynj4l3f080k3amy28ses6setzznv"

    static var recipient: ResolvedRecipient? {
        RecipientIdentifierQuery.resolvedProfileReference(npub)
    }
}

nonisolated enum SupportChatPresentation {
    static var failureTitle: String {
        L10n.string("Couldn't connect to support")
    }

    static var failureMessage: String {
        L10n.string("Please check your connection and try again.")
    }
}

@MainActor
@Observable
final class SupportChatViewModel {
    enum Phase: Equatable {
        case idle
        case loading
        case routing
        case failed
    }

    private(set) var phase: Phase = .idle
    let chatFlow: NewChatFlowViewModel

    init() {
        chatFlow = NewChatFlowViewModel()
    }

    init(chatFlow: NewChatFlowViewModel) {
        self.chatFlow = chatFlow
    }

    var isCreatingChat: Bool {
        chatFlow.starter.isCreating
    }

    func start(using appState: AppState, onOpen: @escaping (String) -> Void) async {
        guard phase == .idle || phase == .failed,
              let recipient = WhiteNoiseSupportContact.recipient
        else {
            if WhiteNoiseSupportContact.recipient == nil {
                phase = .failed
            }
            return
        }

        phase = .loading
        chatFlow.startPrompt = nil
        await chatFlow.startChat(
            accountIdHex: recipient.accountIdHex,
            memberRef: recipient.memberRef,
            using: appState,
            onOpen: { [weak self] groupIdHex in
                self?.phase = .routing
                onOpen(groupIdHex)
            }
        )
        if phase != .routing {
            phase = chatFlow.startPrompt == nil ? .idle : .failed
        }
    }

    func retry(using appState: AppState, onOpen: @escaping (String) -> Void) async {
        guard phase == .failed, chatFlow.startPrompt != nil else {
            await start(using: appState, onOpen: onOpen)
            return
        }

        phase = .loading
        await chatFlow.retryStart(
            using: appState,
            onOpen: { [weak self] groupIdHex in
                self?.phase = .routing
                onOpen(groupIdHex)
            }
        )
        if phase != .routing {
            phase = chatFlow.startPrompt == nil ? .idle : .failed
        }
    }
}

struct SupportChatView: View {
    @Environment(AppState.self) private var appState
    @State private var model = SupportChatViewModel()

    var body: some View {
        Group {
            switch model.phase {
            case .idle, .loading, .routing:
                VStack(spacing: 14) {
                    ProgressView()
                    Text("Connecting to support…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                ContentUnavailableView {
                    Label(
                        SupportChatPresentation.failureTitle,
                        systemImage: "message.badge.waveform"
                    )
                } description: {
                    Text(SupportChatPresentation.failureMessage)
                } actions: {
                    Button("Try Again") {
                        Task {
                            await model.retry(using: appState, onOpen: open)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .localizedNavigationTitle("Chat with support")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(model.isCreatingChat)
        .interactiveDismissDisabled(model.isCreatingChat)
        .task {
            await model.start(using: appState, onOpen: open)
        }
    }

    private func open(_ groupIdHex: String) {
        appState.presentChat(groupIdHex: groupIdHex)
    }
}
