import SwiftUI

/// Detail sheet for one proposal: full diff including context lines, evidence
/// note, and the verdict buttons. Destructive proposals show a danger-styled
/// Deny and no Approve here — approving a deletion happens on the queue card,
/// matching the mockup.
struct ProposalDetailSheet: View {
    let proposal: NilesProposal
    var onApprove: () -> Void = {}
    var onDeny: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(proposal.title)
                .font(.system(size: 18, weight: .bold))
            ToolChip(text: "\(proposal.tool) · proposal \(proposal.id) · \(proposal.agentName)")
            DiffLineList(lines: proposal.diff + proposal.context)
            // Read-back evidence: structured, one row per check. Pending
            // proposals carry none yet — say what will appear instead of
            // rendering an empty block.
            if proposal.evidence.isEmpty {
                Text(Self.pendingEvidenceNote)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Read-back evidence: \(proposal.evidence.filter(\.confirmed).count) of \(proposal.evidence.count) checks confirmed against the live home.")
                        .font(.system(size: 12, weight: .semibold))
                    ForEach(Array(proposal.evidence.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top, spacing: 6) {
                            Text(item.confirmed ? "✓" : "✗")
                                .foregroundStyle(item.confirmed ? NilesTheme.good : NilesTheme.destructive)
                            Text("\(item.claim) — \(item.observed)")
                        }
                        .font(.system(size: 12))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            HStack(spacing: 8) {
                if proposal.isDestructive {
                    ActionButton(title: "Deny", style: .danger) {
                        onDeny()
                        dismiss()
                    }
                    .disabled(!proposal.isPending)
                } else {
                    ActionButton(title: "Approve", style: .primary) {
                        onApprove()
                        dismiss()
                    }
                    .disabled(!proposal.isPending)
                }
                ActionButton(title: "Close", style: .ghost) { dismiss() }
            }
            .padding(.top, 4)
            Spacer()
        }
        .padding(20)
        .presentationDetents([.medium, .large])
    }

    /// Shown in place of the evidence block while nothing has executed —
    /// a pending proposal has no read-back to show yet.
    private static let pendingEvidenceNote = "After approval, Niles re-reads the home from HomeKit and "
        + "attaches the read-back evidence here. Denied and expired proposals never run anything."
}

#Preview("Detail — zone move") {
    ProposalDetailSheet(proposal: InMemoryNilesStore().proposals[0])
}

#Preview("Detail — timer trigger") {
    ProposalDetailSheet(proposal: InMemoryNilesStore().proposals[1])
}

#Preview("Detail — destructive delete") {
    ProposalDetailSheet(proposal: InMemoryNilesStore().proposals[2])
}
