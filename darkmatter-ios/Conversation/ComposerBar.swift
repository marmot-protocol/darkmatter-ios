import SwiftUI

/// Glass-styled composer at the bottom of the conversation screen. Multi-line
/// growing text field + send button. Disabled while a send is in-flight.
struct ComposerBar: View {
    @Binding var draft: String
    let isSending: Bool
    let focusRequest: Int
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
                .foregroundStyle(.primary)
                .background {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.ultraThinMaterial)
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color.black.opacity(0.26))
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                }
                .submitLabel(.send)
                .onSubmit(triggerSend)
                .onChange(of: focusRequest) { _, _ in focusComposer() }
                .onAppear {
                    if focusRequest > 0 {
                        focusComposer()
                    }
                }

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

    private func focusComposer() {
        Task { @MainActor in
            await Task.yield()
            focused = true
        }
    }
}
