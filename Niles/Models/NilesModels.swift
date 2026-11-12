import Foundation
import MCP
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
    /// The launch-revalidation reason a reloaded staged proposal can no
    /// longer be approved — its target object left the home. Rendered on
    /// the queue row; nil for everything else.
    var staleReason: String? = nil

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

/// What kind of graph entity a Home row represents. Only rows carrying a
/// kind and entity id can stage actions — the swipe actions map a row to the
/// same write tool call an agent would make.
enum HomeRowKind: Hashable {
    case room, zone, scene, trigger
}

/// A user-initiated action on a Home row. Rename carries no payload: the
/// screen collects the new name in an alert and passes it to the stage call.
enum HomeRowAction: Hashable {
    case run
    case rename
    case delete
    case setArmed(Bool)

    /// Label and glyph for the swipe buttons.
    var title: String {
        switch self {
        case .run: return "Run"
        case .rename: return "Rename"
        case .delete: return "Delete"
        case .setArmed(true): return "Arm"
        case .setArmed(false): return "Disarm"
        }
    }

    var systemImage: String {
        switch self {
        case .run: return "play.fill"
        case .rename: return "pencil"
        case .delete: return "trash"
        case .setArmed(true): return "shield.fill"
        case .setArmed(false): return "shield.slash.fill"
        }
    }
}

/// One row of the home graph. All four graph sections render the
/// same row shape; disabled rows (e.g. an off trigger) gray out and show an
/// OFF tag instead of a count. `kind` + `entityId` make a row actionable:
/// the swipe actions stage write-tool proposals against that entity.
struct HomeRow: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let subtitle: String
    let systemImage: String
    var trailingCount: Int?
    var isEnabled: Bool = true
    var kind: HomeRowKind?
    var entityId: String?

    init(
        name: String,
        subtitle: String,
        systemImage: String,
        trailingCount: Int? = nil,
        isEnabled: Bool = true,
        kind: HomeRowKind? = nil,
        entityId: String? = nil
    ) {
        self.name = name
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.trailingCount = trailingCount
        self.isEnabled = isEnabled
        self.kind = kind
        self.entityId = entityId
    }

    /// Whether this row can stage any action (has both kind and entity id).
    var isActionable: Bool { kind != nil && entityId != nil }

    /// The swipe-right action: Run for scenes, Arm/Disarm for triggers
    /// (the opposite of its current state). Rooms and zones have no quick
    /// action — their structural changes live in the Queue.
    var primaryAction: HomeRowAction? {
        guard isActionable else { return nil }
        switch kind {
        case .scene: return .run
        case .trigger: return .setArmed(!isEnabled)
        case .room, .zone: return nil
        case nil: return nil
        }
    }

    /// The quick actions for the row menu and context menu, per row kind:
    /// Run for scenes, Arm/Disarm for triggers. Rename and delete are
    /// deliberately absent — HomeKit structural management is not a
    /// Home-tab quick action; those changes are reviewed in the Queue like
    /// everything else (agents still stage them via the MCP write tools).
    var quickActions: [HomeRowAction] {
        guard isActionable else { return [] }
        switch kind {
        case .scene: return [.run]
        case .trigger: return [.setArmed(!isEnabled)]
        case .room, .zone: return []
        case nil: return []
        }
    }

    /// The staged write tool this action maps to, with its MCP arguments —
    /// the same call the agent's write tool would make, so the proposal
    /// lands in the queue as a normal review card. Nil when the row kind
    /// has no tool for the action (e.g. HomeKit has no trigger rename).
    func stageRequest(for action: HomeRowAction, newName: String?) -> (tool: String, arguments: [String: MCP.Value])? {
        guard let kind, let entityId else { return nil }
        let id = MCP.Value.string(entityId)
        switch (kind, action) {
        case (.scene, .run):
            return ("execute_scene", ["sceneId": id])
        case (.scene, .rename):
            return ("rename_scene", ["sceneId": id, "name": .string(newName ?? "")])
        case (.scene, .delete):
            return ("delete_scene", ["sceneId": id])
        case (.trigger, .setArmed(let enabled)):
            return ("set_trigger_state", ["triggerId": id, "enabled": .bool(enabled)])
        case (.trigger, .delete):
            return ("delete_trigger", ["triggerId": id])
        case (.room, .rename):
            return ("rename_room", ["roomId": id, "name": .string(newName ?? "")])
        case (.room, .delete):
            return ("delete_room", ["roomId": id])
        case (.zone, .rename):
            return ("rename_zone", ["zoneId": id, "name": .string(newName ?? "")])
        case (.zone, .delete):
            return ("delete_zone", ["zoneId": id])
        default:
            return nil
        }
    }
}

/// A titled section of the home graph (Rooms, Zones, Scenes, Triggers).
struct HomeSection: Identifiable, Hashable {
    var id: String { title }
    let title: String
    let rows: [HomeRow]
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
