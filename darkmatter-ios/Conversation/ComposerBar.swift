import SwiftUI

/// Liquid-glass composer at the bottom of the conversation screen. Multi-line
/// growing text field + send button. Disabled while a send is in-flight.
struct ComposerBar: View {
    @Binding var draft: String
    let isSending: Bool
    let onSend: () -> Void
    @FocusState private var focused: Bool

    private let controlHeight: CGFloat = 40

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $draft, axis: .vertical)
                .focused($focused)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(minHeight: controlHeight)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
                .submitLabel(.send)
                .onSubmit(triggerSend)

            Button(action: triggerSend) {
                Group {
                    if isSending {
                        ProgressView()
                            .controlSize(.small)
                            .tint(Color(.systemBackground))
                    } else {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Color(.systemBackground))
                    }
                }
                .frame(width: controlHeight, height: controlHeight)
                .background(Circle().fill(canSend ? Color.primary : Color.secondary.opacity(0.3)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .animation(.easeInOut(duration: 0.15), value: canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var canSend: Bool {
        !isSending && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func triggerSend() {
        guard canSend else { return }
        Haptics.tap()
        onSend()
    }
}
