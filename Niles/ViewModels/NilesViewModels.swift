import Foundation
import Observation
import NilesCore

/// Each screen observes one of these protocols, never the store concretely.
/// The in-memory implementation below is what previews render from; the later
/// live-wiring task supplies a real store behind the same protocols.

@MainActor
protocol DashboardViewModel: Observable {
    var homeName: String { get }
    var serverIsRunning: Bool { get }
    var endpoint: String { get }
    var bonjourService: String { get }
    var sessionsSummary: String { get }
    var approvedTodayCount: Int { get }
    var pendingProposals: [NilesProposal] { get }
    var connectedAgents: [AgentConnection] { get }
    func setServerRunning(_ running: Bool)
}

@MainActor
protocol QueueViewModel: Observable {
    var proposals: [NilesProposal] { get }
    /// Proposal id -> decision in flight; present from the tap until the
    /// pipeline settles (or the decision fails and the card reverts).
    var decisionsInFlight: [String: ProposalDecision] { get }
    /// Per-row Undo affordance state. Only executed rows that currently
    /// offer Undo appear: unrevertable operations, already-undone rows, and
    /// refused rows render no Undo button.
    var undoStates: [String: UndoState] { get }
    /// True from the Approve-all tap until the whole batch settles.
    var isApprovingAll: Bool { get }
    func approve(_ id: String)
    func deny(_ id: String)
    func approveAll()
    func undo(_ id: String)
}

/// The direction of a decision whose pipeline round-trip is still running.
/// Cards render an in-progress chip and disable their buttons until it
/// settles, so a tap never looks dead while the pipeline works.
enum ProposalDecision: Hashable {
    case approving
    case denying
}

/// The Undo affordance's state on one executed Queue row. Tapping Undo
/// applies the paired revert immediately — the tap IS the approval — and a
/// refused undo renders its typed cause inline on the row.
enum UndoState: Equatable {
    /// Undo shown, not running.
    case idle
    /// The revert is staging and executing.
    case inFlight
    /// The store refused: the home has diverged from what execution
    /// produced. The divergences name what moved; nothing was changed.
    case conflict([ProposalEvidence])
    /// The store refused: no paired revert exists for this row (its undo
    /// coverage was lost, e.g. a failed read at execution time). The row
    /// stops offering Undo.
    case notRevertable
}

@MainActor
protocol HomeGraphViewModel: Observable {
    var sections: [HomeSection] { get }
}

@MainActor
protocol PairingViewModel: Observable {
    var endpoint: String { get }
    var transportName: String { get }
    var token: String { get }
    var isTokenRevealed: Bool { get }
    var trustedAgents: [AgentConnection] { get }
    func toggleTokenRevealed()
}

/// Preview-ready in-memory store with the mockup's fixture data. Presentational
/// only: approving transitions the local state machine, nothing more.
@MainActor
@Observable
final class InMemoryNilesStore: DashboardViewModel, QueueViewModel, HomeGraphViewModel, PairingViewModel {
    private(set) var serverIsRunning = true
    let homeName = "Gerstman Home"
    let endpoint = "http://192.168.1.24:8901/mcp"
    let bonjourService = "_niles-mcp._tcp.local"
    let sessionsSummary = "2 active"
    let approvedTodayCount = 4
    private(set) var connectedAgents: [AgentConnection] = []

    private(set) var proposals: [NilesProposal] = []
    /// The in-memory store settles decisions synchronously, so nothing is
    /// ever in flight here.
    let decisionsInFlight: [String: ProposalDecision] = [:]
    /// Previews set this directly to render the Undo affordance states.
    var undoStates: [String: UndoState] = [:]
    var isApprovingAll = false

    private(set) var sections: [HomeSection] = []

    let transportName = "Streamable HTTP"
    let token = "nb_7Kq2-mRr4-Tx91-Plo5"
    private(set) var isTokenRevealed = false
    private(set) var trustedAgents: [AgentConnection] = []

    var pendingProposals: [NilesProposal] {
        proposals.filter(\.isPending)
    }

    init(now: Date = Date()) {
        let minute: TimeInterval = 60
        connectedAgents = [
            AgentConnection(name: "Claude Code", detail: "studio-mac · via Bonjour", isActive: true),
            AgentConnection(name: "Obvious Agent", detail: "obvious sandbox · idle 12 min", isActive: false),
        ]

        proposals = [
            NilesProposal(
                id: "prop_8f2a",
                tool: "set_zone_rooms",
                title: "Move Office into Upstairs",
                agentName: "Claude Code",
                createdAt: now.addingTimeInterval(-2 * minute),
                isDestructive: false,
                evidence: [],
                diff: [ProposalDiffLine(.add, "+ Upstairs · add room “Office”")],
                context: [ProposalDiffLine(.plain, "No rooms removed — Master Bedroom and Guest stay.")]
            ),
            NilesProposal(
                id: "prop_8f31",
                tool: "create_timer_trigger",
                title: "Weekday morning trigger",
                agentName: "Claude Code",
                createdAt: now.addingTimeInterval(-14 * minute),
                isDestructive: false,
                evidence: [],
                diff: [
                    ProposalDiffLine(.add, "+ Timer “Weekday morning” · 06:45"),
                    ProposalDiffLine(.add, "+ Repeats Mon–Fri · runs scene “Good Morning”"),
                ],
                context: [ProposalDiffLine(.note, "⚠ Scene “Good Morning” will run unattended on schedule")]
            ),
            NilesProposal(
                id: "prop_8f44",
                tool: "delete_room",
                title: "Delete room “Storage”",
                agentName: "Claude Code",
                createdAt: now.addingTimeInterval(-31 * minute),
                isDestructive: true,
                evidence: [],
                diff: [
                    ProposalDiffLine(.note, "⚠ 3 accessories will move to Default Room"),
                    ProposalDiffLine(.remove, "− Room “Storage”"),
                ],
                context: [ProposalDiffLine(
                    .note,
                    "⚠ HomeKit moves its 3 accessories to the Default Room. Siri, the Home app, and any "
                        + "automations referencing this room will see the change immediately."
                )]
            ),
            // An already-executed change: the Queue row renders the executed
            // chip with read-back evidence and the Undo affordance.
            NilesProposal(
                id: "prop_8f50",
                tool: "create_room",
                title: "Create room “Studio”",
                agentName: "Obvious Agent",
                createdAt: now.addingTimeInterval(-52 * minute),
                isDestructive: false,
                evidence: [
                    ProposalEvidence(claim: "Room “Studio” exists", observed: "Confirmed in the live home", confirmed: true),
                ],
                diff: [ProposalDiffLine(.add, "+ Room “Studio”")],
                context: [],
                state: .executed
            ),
        ]
        undoStates = ["prop_8f50": .idle]

        sections = [
            HomeSection(title: "Rooms", rows: [
                HomeRow(name: "Living Room", subtitle: "Upstairs · Default Room", systemImage: "sofa", trailingCount: 9),
                HomeRow(name: "Kitchen", subtitle: "Downstairs", systemImage: "cooktop", trailingCount: 6),
                HomeRow(name: "Office", subtitle: "No zone", systemImage: "laptopcomputer", trailingCount: 4),
                HomeRow(name: "Master Bedroom", subtitle: "Upstairs", systemImage: "bed.double", trailingCount: 5),
                HomeRow(name: "Storage", subtitle: "Delete pending", systemImage: "shippingbox", trailingCount: 2),
            ]),
            HomeSection(title: "Zones", rows: [
                HomeRow(name: "Upstairs", subtitle: "Living Room, Master Bedroom", systemImage: "house", trailingCount: 2),
                HomeRow(name: "Downstairs", subtitle: "Kitchen, Entry", systemImage: "house", trailingCount: 2),
            ]),
            HomeSection(title: "Scenes", rows: [
                HomeRow(name: "Good Morning", subtitle: "8 actions · 4 accessories", systemImage: "sunrise"),
                HomeRow(name: "Goodnight", subtitle: "12 actions · 7 accessories", systemImage: "moon.stars"),
                HomeRow(name: "Movie Time", subtitle: "5 actions · 3 accessories", systemImage: "film"),
            ]),
            HomeSection(title: "Triggers", rows: [
                HomeRow(name: "Weekday evening", subtitle: "Timer · 17:30 Mon–Fri", systemImage: "clock"),
                HomeRow(name: "Away lights", subtitle: "Event · presence predicate", systemImage: "location"),
                HomeRow(name: "Old porch light", subtitle: "Timer · disabled", systemImage: "lightbulb", isEnabled: false),
            ]),
        ]

        trustedAgents = [
            AgentConnection(name: "Claude Code", detail: "studio-mac · paired Oct 30", isActive: true),
            AgentConnection(name: "Obvious Agent", detail: "obvious sandbox · paired Nov 2", isActive: false),
        ]
    }

    func setServerRunning(_ running: Bool) {
        serverIsRunning = running
    }

    func approve(_ id: String) {
        decide(id, to: .approved)
    }

    func deny(_ id: String) {
        decide(id, to: .denied)
    }

    /// Presentational: staged rows flip to approved so previews react.
    func approveAll() {
        for proposal in proposals where proposal.isPending {
            decide(proposal.id, to: .approved)
        }
    }

    /// Presentational: previews render whatever `undoStates` was seeded with.
    func undo(_ id: String) {}

    private func decide(_ id: String, to next: ProposalState) {
        guard let index = proposals.firstIndex(where: { $0.id == id }),
              proposals[index].state.canTransition(to: next) else { return }
        proposals[index].state = next
    }

    func toggleTokenRevealed() {
        isTokenRevealed.toggle()
    }
}
