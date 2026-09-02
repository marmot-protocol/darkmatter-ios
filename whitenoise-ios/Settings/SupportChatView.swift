import SwiftUI

struct SupportChatView: View {
    @Environment(AppState.self) private var appState
    @State private var model = SupportChatViewModel()
    @State private var requestID: UUID?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    AvatarBubble(
                        seed: WhiteNoiseSupportContact.recipient?.accountIdHex ?? WhiteNoiseSupportContact.npub,
                        title: "White Noise Support",
                        pictureURL: nil
                    )
                    .frame(width: 56, height: 56)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("White Noise Support")
                            .font(.headline)
                        Text("Questions, problems, and suggestions")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            } footer: {
                Text("Ask how something works, report a problem, or share a suggestion.")
            }

            Section {
                Button {
                    requestID = UUID()
                } label: {
                    Text("Start Chat")
                        .hidden()
                        .frame(maxWidth: .infinity)
                        .overlay {
                            OnboardingPrimaryActionLabel(
                                title: "Start Chat",
                                isLoading: model.phase == .loading || model.phase == .routing
                            )
                        }
                }
                .wnPrimaryButtonStyle()
                .controlSize(.large)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .disabled(model.phase == .loading || model.phase == .routing)
            }
        }
        .localizedNavigationTitle("Chat with support")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: requestID) {
            guard requestID != nil else { return }
            await model.start(using: appState) {
                appState.presentChat(groupIdHex: $0)
            }
        }
        .alert(SupportChatPresentation.failureTitle, isPresented: failureBinding) {
            Button("Try Again") { requestID = UUID() }
            Button("Cancel", role: .cancel) { model.dismissFailure() }
        } message: {
            Text(SupportChatPresentation.failureMessage)
        }
        .interactiveDismissDisabled(model.isCreatingChat)
    }

    private var failureBinding: Binding<Bool> {
        Binding(
            get: { model.phase == .failed },
            set: { if !$0 { model.dismissFailure() } }
        )
    }
}

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

    func dismissFailure() {
        guard phase == .failed else { return }
        phase = .idle
        chatFlow.startPrompt = nil
    }
}
