import SwiftUI

/// Support surface reachable from Settings: the project's public donation
/// addresses, each with a scannable QR and a tap-to-copy monospaced row.
struct DonateView: View {
    @State private var qrImages: [String: UIImage] = [:]
    @State private var copiedMethodID: String?
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "heart.fill")
                        .font(.title2)
                        .foregroundStyle(.pink)
                        .padding(14)
                        .background(.pink.opacity(0.12), in: .circle)
                        .accessibilityHidden(true)
                    Text("White Noise is free and open source. Donations keep it that way.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .listRowBackground(Color.clear)

            methodSection(DonatePresentation.lightning, header: Text("Lightning address"))
            methodSection(DonatePresentation.bitcoinSilentPayment, header: Text("Bitcoin silent payment"))
        }
        .localizedNavigationTitle("Donate")
        .task {
            for method in DonatePresentation.methods where qrImages[method.id] == nil {
                qrImages[method.id] = QRCode.image(from: method.qrPayload)
            }
        }
        .onDisappear {
            copyResetTask?.cancel()
        }
    }

    private func methodSection(_ method: DonatePresentation.Method, header: Text) -> some View {
        Section {
            VStack(spacing: 14) {
                qrCard(for: method, label: header)
                copyRow(for: method)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        } header: {
            header
        }
    }

    @ViewBuilder
    private func qrCard(for method: DonatePresentation.Method, label: Text) -> some View {
        if let image = qrImages[method.id] {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 180, height: 180)
                .padding(12)
                .background(.white, in: .rect(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(.quaternary, lineWidth: 0.5)
                )
                .accessibilityLabel(label)
        } else {
            RoundedRectangle(cornerRadius: 16)
                .fill(.quaternary)
                .frame(width: 204, height: 204)
                .overlay(Text("Couldn't render QR").font(.caption).foregroundStyle(.secondary))
        }
    }

    private func copyRow(for method: DonatePresentation.Method) -> some View {
        let copied = copiedMethodID == method.id
        return Button {
            copy(method)
        } label: {
            HStack(spacing: 8) {
                Text(copied ? L10n.string("Copied") : method.displayAddress)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption)
                    .foregroundStyle(copied ? Color.green : Color.accentColor)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func copy(_ method: DonatePresentation.Method) {
        UIPasteboard.general.string = method.address
        Haptics.selection()
        withAnimation(.smooth(duration: 0.15)) { copiedMethodID = method.id }
        // Cancel the previous reset so copying the second address doesn't get
        // its feedback cleared by the first address's timer.
        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if Task.isCancelled { return }
            withAnimation(.smooth(duration: 0.2)) { copiedMethodID = nil }
        }
    }
}
