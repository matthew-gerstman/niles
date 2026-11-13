import SwiftUI
import NilesCore

/// Detail sheet for one proposal: the full diff including context lines, the
/// structured read-back evidence, and the verdict buttons. Destructive
/// proposals show Approve here too — they approve with a standard tap
/// everywhere (user decision Nov 9); severity is carried by the warning
/// glyph and the evidence copy. Executed proposals that still offer Undo
/// carry the Undo action, and a conflicted undo renders its divergences as a
/// native error list — nothing was changed.
///
/// Verdict buttons render only while the proposal is staged: a decided
/// proposal (approved, denied, executed, expired, failed) has no
/// approve/deny affordance at all — not greyed-out ones (user report
/// Nov 13), matching the queue rows' conditional swipes.
struct ProposalDetailSheet: View {
    let proposal: NilesProposal
    var undoState: UndoState?
    var onApprove: () -> Void = {}
    var onDeny: () -> Void = {}
    var onUndo: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    // Screenshot hook: pendings have no evidence rows to scroll to, so the
    // hook expands the sheet instead of scrolling.
    @State private var presentationDetent: PresentationDetent = .medium

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    Section("Summary") {
                        LabeledContent("Tool", value: proposal.tool)
                        LabeledContent("Proposal", value: proposal.id)
                        LabeledContent("Agent", value: proposal.agentName)
                    }
                    if !proposal.diff.isEmpty || !proposal.context.isEmpty {
                        Section("Changes") {
                            DiffLineList(lines: proposal.diff + proposal.context)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                        }
                    }
                    evidenceSection
                    undoSection
                }
                .navigationTitle("Proposal")
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .bottom) {
                    // Decided proposals get no verdict bar at all — the inset
                    // collapses to zero rather than reserving an empty bar.
                    if proposal.isPending {
                        verdictButtons
                    }
                }
                .task {
                    // Screenshot hook: jump past the summary to the evidence.
                    if LaunchArguments.uiProposalDetailEvidence {
                        try? await Task.sleep(for: .milliseconds(600))
                        if proposal.evidence.isEmpty {
                            withAnimation { presentationDetent = .large }
                        } else {
                            withAnimation { proxy.scrollTo(0, anchor: .center) }
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large], selection: $presentationDetent)
    }

    // MARK: - Sections

    /// Read-back evidence as Expected/Found pairs — one ✓/✗ header per
    /// check, then what the change claimed and what the home actually
    /// showed. Pending proposals carry none yet — say what will appear
    /// instead of an empty block.
    @ViewBuilder
    private var evidenceSection: some View {
        Section {
            if proposal.evidence.isEmpty {
                Text(Self.pendingEvidenceNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(proposal.evidence.enumerated()), id: \.offset) { index, item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: Self.evidenceSymbol(for: item))
                                .foregroundStyle(Self.evidenceColor(for: item))
                            Text(Self.evidenceLabel(for: item))
                                .font(.subheadline.weight(.semibold))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Expected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(item.claim)
                                .font(.subheadline)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Found")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(item.observed)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Read-back evidence")
                if !proposal.evidence.isEmpty {
                    Text(Self.evidenceCaption)
                        .font(.footnote)
                        .fontWeight(.regular)
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            if !proposal.evidence.isEmpty {
                Text(Self.evidenceFooter(for: proposal.evidence))
            }
        }
    }

    /// Undo — offered only when the store says this executed proposal can
    /// still revert. A conflicted undo renders its divergences inline as a
    /// native error list: what execution produced, what the home shows now.
    @ViewBuilder
    private var undoSection: some View {
        if let undoState {
            Section {
                Button {
                    onUndo()
                } label: {
                    HStack {
                        Label("Undo this change", systemImage: "arrow.uturn.backward")
                        if undoState == .inFlight {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(undoState == .inFlight)

                if case .conflict(let divergences) = undoState {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.red)
                        Text("Can't undo — the home changed since this ran. Nothing was changed.")
                            .font(.callout)
                            .foregroundStyle(Color.red)
                    }
                    ForEach(Array(divergences.enumerated()), id: \.offset) { _, divergence in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(divergence.claim)
                                    .font(.subheadline)
                                Text(divergence.observed)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if undoState == .notRevertable {
                    Text("No revert is available for this change.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Undo")
            }
        }
    }

    // MARK: - Verdicts

    /// Deny (destructive red) and Approve (prominent green, matching the
    /// queue's approve swipe) over a bar material. Rendered only for staged
    /// proposals — see the safeAreaInset call. The explicit tints matter:
    /// the app-wide `.tint(.white)` otherwise starves both standard styles
    /// of their semantic colors, rendering them as washed-out neutral pills
    /// (the same white-tint class as the pairing row's white-on-white
    /// labels). Dismissal itself is the sheet's native drag gesture.
    private var verdictButtons: some View {
        HStack(spacing: 12) {
            Button(role: .destructive) {
                onDeny()
                dismiss()
            } label: {
                Text("Deny")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            Button {
                onApprove()
                dismiss()
            } label: {
                Text("Approve")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    /// Shown in place of the evidence block while nothing has executed —
    /// a pending proposal has no read-back to show yet.
    private static let pendingEvidenceNote = "After approval, Niles re-reads the home from HomeKit and "
        + "attaches the read-back evidence here. Denied and expired proposals never run anything."

    /// The one-line caption above the evidence list: what a check IS.
    private static let evidenceCaption = "Niles re-reads your home after executing. "
        + "Each check compares what was intended with what your home now shows."

    /// Three evidence states, rendered distinctly: confirmed (green), not
    /// confirmed (red), and not run (gray — the batch aborted before the
    /// entry was ever attempted).
    private static func evidenceSymbol(for item: ProposalEvidence) -> String {
        item.notRun ? "minus.circle.fill" : (item.confirmed ? "checkmark.circle.fill" : "xmark.circle.fill")
    }

    private static func evidenceColor(for item: ProposalEvidence) -> Color {
        item.notRun ? Color.secondary : (item.confirmed ? Color.green : Color.red)
    }

    private static func evidenceLabel(for item: ProposalEvidence) -> String {
        item.notRun ? "Not run" : (item.confirmed ? "Confirmed" : "Not confirmed")
    }

    /// The footer tally. Not-run entries are neither confirmed checks nor
    /// failed ones — they are called out separately so an aborted batch's
    /// footer doesn't read as "0 of 3 checks confirmed" without saying why.
    private static func evidenceFooter(for evidence: [ProposalEvidence]) -> String {
        let confirmed = evidence.filter(\.confirmed).count
        var footer = "\(confirmed) of \(evidence.count) checks confirmed against the live home."
        let notRun = evidence.filter(\.notRun).count
        if notRun > 0 {
            footer += " \(notRun) never ran — the batch aborted before them."
        }
        return footer
    }
}

#Preview("Detail — zone move") {
    ProposalDetailSheet(proposal: InMemoryNilesStore().proposals[2])
}

#Preview("Detail — timer trigger") {
    ProposalDetailSheet(proposal: InMemoryNilesStore().proposals[3])
}

#Preview("Detail — destructive delete") {
    ProposalDetailSheet(proposal: InMemoryNilesStore().proposals[4])
}

#Preview("Detail — decided, executed") {
    // The user report this sheet fixes: an executed proposal must render
    // with no verdict bar — evidence and (when available) Undo only.
    ProposalDetailSheet(proposal: InMemoryNilesStore().proposals[0])
}

#Preview("Detail — conflicted undo") {
    ProposalDetailSheet(
        proposal: InMemoryNilesStore().proposals[1],
        undoState: .conflict([
            ProposalEvidence(
                claim: "Room “Studio” exists",
                observed: "No room named “Studio” exists — it was deleted after execution",
                confirmed: false
            ),
        ])
    )
}
