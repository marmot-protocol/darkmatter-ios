import SwiftUI
import MarmotKit

/// Projects a message's durable kind-1009 edit records into the rows shown by
/// the edit-history sheet. The engine exposes no version-read API; versions
/// are sourced from the timeline's edit records, which the edit projection
/// cache already retains per target message.
nonisolated enum EditHistoryPresentation {
    /// Bounds sanitized row bodies to the plain-text flattener's own budget,
    /// so hostile content is capped once, consistently.
    static let maxRowBodyLength = 1000

    struct Row: Identifiable, Equatable {
        /// The version's own message id (edits and the original are distinct records).
        let id: String
        /// 0 for the original, then 1... in the order the edits were applied.
        let versionNumber: Int
        /// Sanitized plain text via the budgeted flattener.
        let body: String
        let recordedAt: UInt64
        let isCurrent: Bool
        let isOriginal: Bool
    }

    /// The actions-menu gate: history exists only once a durable edit landed,
    /// and a deleted message hides its edit trail like it hides its body.
    static func shouldOffer(editCount: Int, isDeleted: Bool) -> Bool {
        editCount > 0 && !isDeleted
    }

    /// Newest-first rows: the current version, earlier revisions, then the
    /// original. `edits` are re-sorted defensively with the same ordering the
    /// projection cache applies, so callers can't change what "current" means.
    static func rows(
        original: AppMessageRecordFfi,
        edits: [AppMessageRecordFfi],
        mentionDisplayName: MarkdownMentionResolver? = nil
    ) -> [Row] {
        let ordered = edits.sorted { lhs, rhs in
            if lhs.recordedAt != rhs.recordedAt {
                return lhs.recordedAt < rhs.recordedAt
            }
            return lhs.messageIdHex < rhs.messageIdHex
        }
        var rows: [Row] = []
        rows.reserveCapacity(ordered.count + 1)
        for (index, edit) in ordered.enumerated().reversed() {
            rows.append(Row(
                id: edit.messageIdHex,
                versionNumber: index + 1,
                body: body(of: edit, mentionDisplayName: mentionDisplayName),
                recordedAt: edit.recordedAt,
                isCurrent: index == ordered.count - 1,
                isOriginal: false
            ))
        }
        rows.append(Row(
            id: original.messageIdHex,
            versionNumber: 0,
            body: body(of: original, mentionDisplayName: mentionDisplayName),
            recordedAt: original.recordedAt,
            isCurrent: ordered.isEmpty,
            isOriginal: true
        ))
        return rows
    }

    static func timestampLabel(
        _ timestamp: UInt64,
        locale: Locale = AppLanguage.currentLocale
    ) -> String? {
        guard timestamp > 0 else { return nil }
        let style = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale)
        return Date(timeIntervalSince1970: TimeInterval(timestamp)).formatted(style)
    }

    private static func body(
        of record: AppMessageRecordFfi,
        mentionDisplayName: MarkdownMentionResolver?
    ) -> String {
        let flattened: String
        if record.contentTokens.blocks.isEmpty {
            flattened = CanonicalMentionDisplayProjection.project(record.plaintext) { npub in
                mentionDisplayName?(MarkdownNostrEntityFfi(hrp: .npub, bech32: npub))
            }.text
        } else {
            flattened = MarkdownPlainText.flatten(
                record.contentTokens,
                mentionDisplayName: mentionDisplayName
            ) ?? record.plaintext
        }
        return ContentSanitizer.compactSingleLine(flattened, maxLength: maxRowBodyLength) ?? ""
    }
}

struct EditHistorySheet: View {
    @Environment(\.dismiss) private var dismiss

    let rows: [EditHistoryPresentation.Row]

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader
            Divider()

            ScrollView {
                VStack(spacing: 12) {
                    ForEach(rows) { row in
                        versionCard(row)
                    }
                }
                .padding(16)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var sheetHeader: some View {
        HStack {
            Text("Edit history")
                .font(.headline)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .font(.headline)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func versionCard(_ row: EditHistoryPresentation.Row) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                versionLabel(row)
                Spacer(minLength: 8)
                if let timestamp = EditHistoryPresentation.timestampLabel(row.recordedAt) {
                    Text(timestamp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !row.body.isEmpty {
                Text(row.body)
                    .font(.body)
                    .foregroundStyle(row.isCurrent ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func versionLabel(_ row: EditHistoryPresentation.Row) -> some View {
        if row.isCurrent {
            Text("Current")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.tint.opacity(0.18), in: Capsule())
                .foregroundStyle(.tint)
        } else if row.isOriginal {
            Text("Original")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        } else {
            Text(L10n.formatted("Version %lld", Int64(row.versionNumber)))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }
}
