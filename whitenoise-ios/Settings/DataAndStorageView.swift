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

            Section {
                ForEach(MediaAutoDownloadType.allCases, id: \.self) { type in
                    NavigationLink {
                        AutoDownloadLevelView(type: type, title: typeTitle(type), store: store)
                    } label: {
                        HStack {
                            Text(typeTitle(type))
                            Spacer()
                            Text(Self.levelTitle(store.matrix.level(for: type)))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Button(role: .destructive) {
                    store.resetToDefaults()
                } label: {
                    Text("Reset auto-download settings")
                }
            } header: {
                Text("Media auto-download")
            } footer: {
                Text("Media that isn't downloaded automatically shows a download button instead.")
            }
        }
        .navigationTitle("Data and storage")
        .navigationBarTitleDisplayMode(.inline)
    }

    static func levelTitle(_ level: MediaAutoDownloadLevel) -> String {
        switch level {
        case .never: return L10n.string("Never")
        case .wifiOnly: return L10n.string("Wi-Fi")
        case .wifiAndCellular: return L10n.string("Wi-Fi and Cellular")
        }
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
        case .audio: return L10n.string("Audio")
        case .video: return L10n.string("Videos")
        case .document: return L10n.string("Files")
        }
    }
}

/// Radio-style level picker for one media type: Never / Wi-Fi /
/// Wi-Fi and Cellular, checkmark on the current choice.
private struct AutoDownloadLevelView: View {
    let type: MediaAutoDownloadType
    let title: String
    let store: MediaAutoDownloadStore

    var body: some View {
        List {
            Section {
                ForEach(MediaAutoDownloadLevel.allCases, id: \.self) { level in
                    Button {
                        store.setLevel(level, for: type)
                    } label: {
                        HStack {
                            Text(DataAndStorageView.levelTitle(level))
                                .foregroundStyle(.primary)
                            Spacer()
                            if store.matrix.level(for: type) == level {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
