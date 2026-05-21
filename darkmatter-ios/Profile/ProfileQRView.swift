import SwiftUI

/// Full-page shareable identity card: avatar, display name, npub (tap to
/// copy), and a large QR encoding the `darkmatter://profile/<npub>` deep
/// link. A "Scan QR Code" button opens the camera scanner.
struct ProfileQRView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let accountIdHex: String

    @State private var showScanner = false
    @State private var scanError: String?
    @State private var copied = false
    @State private var scanned: AppState.ProfileLink?

    private var npub: String { appState.npub(forAccountIdHex: accountIdHex) }
    private var deepLink: String { DeepLink.profile(npub: npub).url.absoluteString }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer(minLength: 8)

                AvatarBubble(
                    seed: accountIdHex,
                    title: appState.displayName(forAccountIdHex: accountIdHex),
                    pictureURL: appState.avatarURL(forAccountIdHex: accountIdHex)
                )
                .frame(width: 88, height: 88)

                Text(appState.displayName(forAccountIdHex: accountIdHex))
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)

                Button(action: copyNpub) {
                    HStack(spacing: 8) {
                        Text(copied ? "Copied" : IdentityFormatter.short(npub))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(copied ? Color.green : Color.secondary)
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                            .foregroundStyle(copied ? Color.green : Color.accentColor)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                qrCard

                Spacer(minLength: 8)

                Button {
                    scanError = nil
                    showScanner = true
                } label: {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal, 24)

                if let scanError {
                    Text(scanError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 24)
                }
            }
            .padding(.bottom, 16)
            .navigationTitle("My Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: deepLink) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
            .fullScreenCover(isPresented: $showScanner) {
                ScannerSheet { result in
                    showScanner = false
                    handleScan(result)
                }
            }
            .sheet(item: $scanned) { link in
                ProfileView(npub: link.npub)
            }
        }
    }

    private var qrCard: some View {
        Group {
            if let image = QRCode.image(from: deepLink) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 240, height: 240)
                    .padding(16)
                    .background(.white, in: .rect(cornerRadius: 20))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .strokeBorder(.quaternary, lineWidth: 0.5)
                    )
            } else {
                RoundedRectangle(cornerRadius: 20)
                    .fill(.quaternary)
                    .frame(width: 272, height: 272)
                    .overlay(Text("Couldn't render QR").font(.caption).foregroundStyle(.secondary))
            }
        }
    }

    private func copyNpub() {
        UIPasteboard.general.string = npub
        Haptics.selection()
        withAnimation(.smooth(duration: 0.15)) { copied = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.smooth(duration: 0.2)) { copied = false }
        }
    }

    private func handleScan(_ raw: String) {
        guard case let .profile(scannedNpub) = DeepLink.parse(string: raw) else {
            scanError = "That QR code isn't a Dark Matter profile."
            Haptics.error()
            return
        }
        Haptics.success()
        scanned = AppState.ProfileLink(npub: scannedNpub)
    }
}

/// Wraps the scanner in its own nav chrome with a Cancel button + error
/// surface, so the camera view has a way out.
private struct ScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onScan: (String) -> Void
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                QRScannerView(
                    onScan: { onScan($0) },
                    onError: { error = $0 }
                )
                .ignoresSafeArea()

                VStack {
                    Spacer()
                    if let error {
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.white)
                            .padding()
                            .background(.black.opacity(0.6), in: .rect(cornerRadius: 12))
                            .padding(.bottom, 40)
                    } else {
                        Text("Point the camera at a Dark Matter profile QR")
                            .font(.callout)
                            .foregroundStyle(.white)
                            .padding()
                            .background(.black.opacity(0.5), in: .capsule)
                            .padding(.bottom, 40)
                    }
                }
            }
            .navigationTitle("Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .toolbarBackground(.visible, for: .navigationBar)
        }
    }
}
