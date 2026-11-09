import Foundation
import NilesCore

/// One line of a proposal's human-readable diff, as rendered on review cards.
struct ProposalDiffLine: Identifiable, Hashable {
    enum Kind: Hashable {
        /// A line being added — green treatment.
        case add
        /// A line being removed — red treatment.
        case remove
        /// A blast-radius or validation warning — amber treatment.
        case note
        /// Neutral context, only shown in the detail sheet.
        case plain
    }

    let id = UUID()
    let kind: Kind
    let text: String

    init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

/// A staged write proposal. Nothing in here mutates HomeKit — it is the
/// review-card payload the agent's request turns into.
struct NilesProposal: Identifiable, Hashable {
    let id: String
    let tool: String
    let title: String
    let agentName: String
    let createdAt: Date
    /// Destructive proposals (room/zone/scene deletion) get the danger treatment:
    /// red edge on the card, danger-styled Deny in the detail sheet.
    let isDestructive: Bool
    /// Post-execution read-back evidence, structured: what each change
    /// claimed, what the home actually showed, and whether they agree.
    /// Empty until the proposal executes.
    let evidence: [ProposalEvidence]
    /// Diff lines shown on the queue card.
    let diff: [ProposalDiffLine]
    /// Extra context lines shown only in the detail sheet.
    var context: [ProposalDiffLine] = []

    var isPending: Bool { state == .staged }
    /// Defaults to staged — every proposal enters the pipeline staged.
    var state: ProposalState = .staged
    /// Set on a revert proposal: the id of the executed proposal it reverts.
    var revertsProposalId: String?
}

/// An agent seen on the LAN, for the dashboard and pairing lists.
struct AgentConnection: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let detail: String
    let isActive: Bool
}

/// One row of the read-only home graph. All four graph sections render the
/// same row shape; disabled rows (e.g. an off trigger) gray out and show an
/// OFF tag instead of a count.
struct HomeRow: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let subtitle: String
    let systemImage: String
    var trailingCount: Int?
    var isEnabled: Bool = true

    init(name: String, subtitle: String, systemImage: String, trailingCount: Int? = nil, isEnabled: Bool = true) {
        self.name = name
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.trailingCount = trailingCount
        self.isEnabled = isEnabled
    }
}

/// A titled section of the home graph (Rooms, Zones, Scenes, Triggers).
struct HomeSection: Identifiable, Hashable {
    var id: String { title }
    let title: String
    let rows: [HomeRow]
}

/// A `key: value` line on the dashboard or pairing connection card.
struct KeyValueRow: Identifiable, Hashable {
    var id: String { key }
    let key: String
    let value: String
}

/// Relative timestamps like "2 min ago" / "now", deterministic and pure so
/// previews and tests stay stable.
enum RelativeTime {
    static func label(for date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        let minutes = Int(seconds) / 60
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) hr ago" }
        return "\(hours / 24) d ago"
    }
}
