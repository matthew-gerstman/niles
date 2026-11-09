import SwiftUI

/// Approvals queue: one review card per staged proposal, tapping a card opens
/// its detail sheet. Approve/Deny act immediately on the card, as in the mockup.
struct ApprovalsScreen: View {
    var model: any ApprovalsViewModel

    @State private var openDetail: NilesProposal?

    var body: some View {
        ScreenScaffold(title: "Approvals", subtitle: "Nothing changes until you approve it") {
            if model.proposals.isEmpty {
                EmptyStateCard(text: "No proposals yet. When an agent wants to change your home, its request shows up here.")
            } else {
                ForEach(model.proposals) { proposal in
                    ProposalCard(
                        proposal: proposal,
                        decision: model.decisionsInFlight[proposal.id],
                        onOpenDetail: { openDetail = proposal },
                        onApprove: { model.approve(proposal.id) },
                        onDeny: { model.deny(proposal.id) }
                    )
                }
            }
        }
        .sheet(item: $openDetail) { snapshot in
            // Re-read from the model so the sheet reflects approve/deny made on the card.
            if let proposal = model.proposals.first(where: { $0.id == snapshot.id }) {
                ProposalDetailSheet(
                    proposal: proposal,
                    onApprove: { model.approve(proposal.id) },
                    onDeny: { model.deny(proposal.id) }
                )
            }
        }
    }
}

/// One proposal review card. Destructive proposals get the red edge; once a
/// verdict is recorded the buttons disable and a status chip appears. While a
/// decision's pipeline round-trip is still running, `decision` shows an
/// in-progress chip and disables the buttons before the verdict state lands.
struct ProposalCard: View {
    let proposal: NilesProposal
    var decision: ProposalDecision?
    var onOpenDetail: () -> Void = {}
    var onApprove: () -> Void = {}
    var onDeny: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(proposal.title)
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Text(RelativeTime.label(for: proposal.createdAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            ToolChip(text: "\(proposal.tool) · \(proposal.id)")
            DiffLineList(lines: proposal.diff)
            HStack(spacing: 8) {
                ActionButton(title: "Approve", style: .primary, action: onApprove)
                    .disabled(!proposal.isPending || decision != nil)
                ActionButton(title: "Deny", style: .ghost, action: onDeny)
                    .disabled(!proposal.isPending || decision != nil)
            }
            .padding(.top, 2)
            if let chip = statusChip {
                Text(chip.text)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(chip.color)
            }
        }
        .card(accent: proposal.isDestructive ? NilesTheme.bad : NilesTheme.brand)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenDetail)
    }

    private var statusChip: (text: String, color: Color)? {
        if let decision {
            switch decision {
            case .approving: return ("Approving…", NilesTheme.brand)
            case .denying: return ("Denying…", NilesTheme.bad)
            }
        }
        switch proposal.state {
        case .staged, .approved: return nil
        case .executed: return ("Executed", NilesTheme.good)
        case .denied: return ("Denied", NilesTheme.bad)
        case .expired: return ("Expired", NilesTheme.warn)
        case .failed: return ("Failed", NilesTheme.bad)
        }
    }
}

#Preview("Approvals") {
    ApprovalsScreen(model: InMemoryNilesStore())
}

#Preview("Approvals — deciding") {
    struct DecidingStore: ApprovalsViewModel {
        private let base = InMemoryNilesStore()
        var proposals: [NilesProposal] { base.proposals }
        var decisionsInFlight: [String: ProposalDecision] { [base.proposals[0].id: .approving] }
        func approve(_ id: String) { base.approve(id) }
        func deny(_ id: String) { base.deny(id) }
    }
    return ApprovalsScreen(model: DecidingStore())
}

#Preview("Approvals — empty") {
    struct EmptyStore: ApprovalsViewModel {
        var proposals: [NilesProposal] { [] }
        var decisionsInFlight: [String: ProposalDecision] { [:] }
        func approve(_ id: String) {}
        func deny(_ id: String) {}
    }
    return ApprovalsScreen(model: EmptyStore())
}
