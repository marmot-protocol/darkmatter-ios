import SwiftUI
import MarmotKit

/// Membership extension for an existing group, built on the same searchable
/// people picker as group creation so the two never drift. People already in
/// the group are excluded; a pasted or scanned identifier auto-selects since
/// it names an unambiguous target.
struct AddMembersSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let normalize: (String) async throws -> MemberRefFfi
    let onSubmit: ([String]) async throws -> Void
    var excludedAccountIds: Set<String> = []
    var excludedMemberMessage = AddMembersPresentation.existingMemberMessage

    @State private var model = AddMembersSheetViewModel()
    @State private var showScanner = false

    var body: some View {
        @Bindable var query = model.query
        NavigationStack {
            List {
                if !model.selection.isEmpty {
                    Section {
                        SelectedRecipientRail(members: model.selection.members) { member in
                            model.selection.remove(accountIdHex: member.accountIdHex)
                        }
                        .listRowInsets(EdgeInsets())
                    }
                }

                if query.isBlank {
                    Section {
                        RecipientQuickActionRow(
                            title: "Scan QR Code",
                            systemImage: "qrcode.viewfinder",
                            action: { showScanner = true }
                        )
                    }
                    .disabled(model.isInviting)
                }

                if query.isIdentifierQuery {
                    RecipientResolutionSection(
                        query: model.query,
                        excludedAccountIds: excludedAccountIds,
                        isBusy: model.isInviting,
                        selectedAccountIds: selectedAccountIds,
                        excludedMessage: { excludedMessage(for: $0) },
                        onRetry: { model.query.queryChanged(using: appState) },
                        onSelect: { resolved in
                            Task { await selectResolved(resolved) }
                        }
                    )
                } else {
                    peopleSection
                }

                if let error = model.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query.text,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: Text("Search people or paste a profile")
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(model.isInviting)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(model.isInviting ? L10n.string("Inviting…") : L10n.string("Invite")) {
                        Task {
                            await model.invite(onSubmit: onSubmit, dismiss: { dismiss() })
                        }
                    }
                    .disabled(!AddMembersPresentation.canInvite(
                        stagedCount: model.selection.count,
                        isInviting: model.isInviting
                    ))
                }
            }
            .interactiveDismissDisabled(model.isInviting)
            .task { await model.directory.load(using: appState) }
            .onChange(of: model.query.text) { _, _ in
                model.query.queryChanged(using: appState)
            }
            .onChange(of: model.query.resolution) { _, resolution in
                guard case .resolved(let resolved) = resolution else { return }
                Task { await autoSelect(resolved) }
            }
            .fullScreenCover(isPresented: $showScanner) {
                ScannerSheet { raw in
                    showScanner = false
                    handleScan(raw)
                }
                .appAppearance()
            }
        }
    }

    private var title: Text {
        if model.selection.isEmpty {
            return Text("Add Members")
        }
        return Text(L10n.plural("%lld selected", Int64(model.selection.count)))
    }

    private var selectedAccountIds: Set<String> {
        Set(model.selection.members.map { $0.accountIdHex.lowercased() })
    }

    private func excludedMessage(for accountIdHex: String) -> String {
        let selfIds = AddMembersPresentation.excludedNewChatAccountIds(
            activeAccountIdHex: appState.activeAccount?.accountIdHex
        )
        return selfIds.contains(accountIdHex)
            ? AddMembersPresentation.selfRecipientMessage
            : excludedMemberMessage
    }

    @ViewBuilder
    private var peopleSection: some View {
        let candidates = RecipientSearch.browse(
            model.directory.candidates,
            query: model.query.text,
            excludedAccountIds: excludedAccountIds,
            fields: { RecipientDirectory.matchFields(for: $0, appState: appState) }
        )
        if model.directory.isLoading && model.directory.candidates.isEmpty {
            Section {
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                .padding(.vertical, 16)
            }
        } else if candidates.isEmpty {
            Section {
                if model.query.isBlank {
                    Text("Paste an npub or scan a QR code to add someone you haven't chatted with yet.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView.search(text: model.query.trimmedText)
                }
            }
        } else {
            Section {
                ForEach(candidates) { candidate in
                    memberRow(candidate)
                }
            } header: {
                if model.query.isBlank {
                    Text("People")
                }
            }
        }
    }

    private func memberRow(_ candidate: RecipientCandidate) -> some View {
        let isSelected = model.selection.isSelected(accountIdHex: candidate.accountIdHex)
        return Button {
            model.toggle(candidate, excludedAccountIds: excludedAccountIds)
        } label: {
            RecipientRow(accountIdHex: candidate.accountIdHex, npub: candidate.npub) {
                RecipientSelectionIndicator(isSelected: isSelected)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(model.isInviting)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Explicit tap on a resolved row; shares the normalize-then-stage path
    /// with the automatic selection below.
    private func selectResolved(_ resolved: ResolvedRecipient) async {
        await model.selectResolved(
            resolved,
            excludedAccountIds: excludedAccountIds,
            normalize: normalize
        )
    }

    /// A pasted/scanned identifier is an unambiguous target, so it selects
    /// itself once resolved — unless it's excluded, already selected, or an
    /// invite is in flight.
    private func autoSelect(_ resolved: ResolvedRecipient) async {
        let normalized = resolved.accountIdHex.lowercased()
        guard !model.isInviting,
              !excludedAccountIds.contains(normalized),
              !model.selection.isSelected(accountIdHex: normalized)
        else { return }
        await selectResolved(resolved)
    }

    private func handleScan(_ raw: String) {
        guard AddMembersPresentation.memberRef(fromScannedPayload: raw) != nil else {
            Haptics.error()
            appState.present(.error(L10n.string("That QR code isn't a White Noise profile.")))
            return
        }
        Haptics.success()
        model.query.text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        model.query.queryChanged(using: appState)
    }
}
