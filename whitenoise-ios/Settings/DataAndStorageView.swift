import SwiftUI

/// Data-and-storage preferences: outbound media quality and the per-type ×
/// per-network auto-download matrix. Semantics are shared with the Android
/// client so the same choices mean the same behavior on both platforms.
struct DataAndStorageView: View {
    @State private var quality = MediaQualityStore.quality()
    @State private var store = MediaAutoDownloadStore.shared

    var body: some View {
        List {
            Section {
                ForEach(MediaQuality.allCases, id: \.self) { level in
                    Button {
                        quality = level
                        MediaQualityStore.setQuality(level)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(qualityTitle(level))
                                    .foregroundStyle(.primary)
                                Text(qualitySubtitle(level))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if quality == level {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Media send quality")
            } footer: {
                Text("Quality is a ceiling — smaller media is never upscaled. Identifying photo metadata, like location, is always removed before sending at every quality level.")
            }

            ForEach(MediaAutoDownloadNetwork.allCases, id: \.self) { network in
                Section {
                    ForEach(MediaAutoDownloadType.allCases, id: \.self) { type in
                        Toggle(isOn: Binding(
                            get: { store.matrix.isEnabled(type, on: network) },
                            set: { store.setEnabled(type, on: network, to: $0) }
                        )) {
                            Text(typeTitle(type))
                        }
                    }
                } header: {
                    networkHeader(network)
                }
            }

            Section {
                EmptyView()
            } footer: {
                Text("When a connection matches several conditions at once, the most restrictive one wins. Media that isn't downloaded automatically shows a download button instead.")
            }
        }
        .navigationTitle("Data and storage")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func qualityTitle(_ level: MediaQuality) -> String {
        switch level {
        case .low: return L10n.string("Low")
        case .standard: return L10n.string("Standard")
        case .high: return L10n.string("High")
        case .original: return L10n.string("Original")
        }
    }

    private func qualitySubtitle(_ level: MediaQuality) -> String {
        switch level {
        case .low: return L10n.string("Smallest data use")
        case .standard: return L10n.string("Balanced quality and data use")
        case .high: return L10n.string("Sharper photos, more data")
        case .original: return L10n.string("Full resolution, metadata still removed")
        }
    }

    private func typeTitle(_ type: MediaAutoDownloadType) -> String {
        switch type {
        case .image: return L10n.string("Photos")
        case .audio: return L10n.string("Voice messages")
        case .video: return L10n.string("Videos")
        case .document: return L10n.string("Files")
        }
    }

    private func networkHeader(_ network: MediaAutoDownloadNetwork) -> Text {
        switch network {
        case .wifi: return Text("Auto-download on Wi-Fi")
        case .mobile: return Text("Auto-download on cellular")
        case .metered: return Text("Auto-download on limited data")
        }
    }
}
