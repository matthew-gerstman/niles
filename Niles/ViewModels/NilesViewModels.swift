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
    /// Stages a row's swipe action through the same proposal pipeline agents
    /// use — the proposal lands in the queue and nothing applies until the
    /// human approves it. Failures are logged, never applied.
    func stage(row: HomeRow, action: HomeRowAction, newName: String?) async
}

/// One live MCP session of a paired agent, as the detail screen renders it:
/// the client's own name and its timeline. Display-only; the token never
/// reaches this layer.
struct AgentSessionRow: Identifiable, Equatable {
    let id: String
    let clientName: String
    let startedAt: Date
    let lastAccessedAt: Date
}

/// One row of the paired-agents list: a credential paired since launch.
/// The token itself never reaches this layer — rows carry display-only
/// fields.
struct PairedAgentRow: Identifiable, Equatable {
    let id: UUID
    let name: String
    /// When the credential was created.
    let pairedAt: Date
    /// Live sessions created by this agent's token, newest first.
    let sessions: [AgentSessionRow]
}

@MainActor
protocol PairingViewModel: Observable {
    var endpoint: String { get }
    var transportName: String { get }
    /// The live six-digit code, when one is minted and unexpired. A challenge,
    /// not a secret — the bearer token it exchanges for never renders here.
    var pairingCode: String? { get }
    /// When the live code expires — the countdown's input.
    var codeExpiresAt: Date? { get }
    /// Every paired credential, named and dated, each revocable.
    var pairedAgents: [PairedAgentRow] { get }
    /// Revokes one agent: deletes its credential and closes its live session.
    func revokeAgent(_ id: UUID) async
}

/// The on-device agent's Settings status: availability (stating the reason
/// when unavailable) and session usage. No run entry here — requests arrive
/// via Siri; this surface states whether the agent can run at all.
@MainActor
protocol AgentStatusViewModel: Observable {
    var agentAvailability: AgentAvailability { get }
    var agentUsage: AgentSessionUsage { get }
}

/// Preview-ready in-memory store with the mockup's fixture data. Presentational
/// only: approving transitions the local state machine, nothing more.
@MainActor
@Observable
final class InMemoryNilesStore: DashboardViewModel, QueueViewModel, HomeGraphViewModel, PairingViewModel, AgentStatusViewModel, ChatViewModel {
    private(set) var serverIsRunning = true
    let homeName = "Gerstman Home"
    let endpoint = "http://192.168.1.24:8901/mcp"
    let bonjourService = "_niles-mcp._tcp.local"
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
    /// Previews render the available state; the live store evaluates the
    /// gate for real (spec art_VrC0iUUA §Availability gate).
    var agentAvailability: AgentAvailability = .available
    var agentUsage = AgentSessionUsage()
    // MARK: ChatViewModel — transcript storage; the send path lives in
    // ChatViewModel.swift as the presentational fixture.
    private(set) var entries: [ChatEntry] = []
    private(set) var isChatRunInFlight = false
    private(set) var pairingCode: String?
    private(set) var codeExpiresAt: Date?
    private(set) var pairedAgents: [PairedAgentRow] = []

    var pendingProposals: [NilesProposal] {
        proposals.filter(\.isPending)
    }

    /// Presentational: the fixture always has somewhere to send from.
    var canSend: Bool {
        !isChatRunInFlight
    }

    /// Presentational chat for previews: a send replays a canned staged
    /// turn — optimistic user row, resolved agent row, and a proposal chip
    /// linking into the seeded Queue — so every transcript state renders
    /// without the agent core.
    func send(_ text: String) async {
        guard !isChatRunInFlight else { return }
        entries.append(ChatEntry(id: UUID(), role: .user, text: text))
        let pending = ChatEntry(id: UUID(), role: .agent, text: "", state: .running)
        entries.append(pending)
        isChatRunInFlight = true
        defer { isChatRunInFlight = false }

        let proposal = NilesProposal(
            id: "prop_chat_\(proposals.count + 1)",
            tool: "create_timer_trigger",
            title: "Living Room evening dim",
            agentName: "Niles",
            createdAt: Date(),
            isDestructive: false,
            evidence: [],
            diff: [ProposalDiffLine(.add, "+ Timer “Living Room evening dim” · 20:00")],
            context: []
        )
        proposals.append(proposal)
        ChatTranscript.resolve(pending.id, in: &entries, result: AgentRunResult(
            summary: "I found the Living Room and staged a trigger that sets its lights to 40% at 8:00 PM. Review it in the Queue.",
            stagedProposalIds: [proposal.id]
        ))
    }

    init(now: Date = Date()) {
        let minute: TimeInterval = 60
        pairingCode = "483920"
        codeExpiresAt = now.addingTimeInterval(30 * minute)
        // The launch rule, mirrored for previews: only credentials paired
        // since this store's creation render. Obvious Agent paired at
        // launch and shows; Claude Code paired nine days ago and is
        // filtered out, so the preview exercises the launch filter.
        pairedAgents = [
            PairedAgentRow(
                id: UUID(),
                name: "Obvious Agent",
                pairedAt: now,
                sessions: [
                    AgentSessionRow(
                        id: "fixture-session-1",
                        clientName: "Obvious Agent",
                        startedAt: now.addingTimeInterval(-12 * 60),
                        lastAccessedAt: now
                    ),
                ]
            ),
            PairedAgentRow(
                id: UUID(),
                name: "Claude Code",
                pairedAt: now.addingTimeInterval(-9 * 24 * 60 * 60),
                sessions: []
            ),
        ].filter { $0.pairedAt >= now }
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
                HomeRow(name: "Living Room", subtitle: "Upstairs · Default Room", systemImage: "sofa", trailingCount: 9, kind: .room, entityId: "room-1"),
                HomeRow(name: "Kitchen", subtitle: "Downstairs", systemImage: "cooktop", trailingCount: 6, kind: .room, entityId: "room-2"),
                HomeRow(name: "Office", subtitle: "No zone", systemImage: "laptopcomputer", trailingCount: 4, kind: .room, entityId: "room-3"),
                HomeRow(name: "Master Bedroom", subtitle: "Upstairs", systemImage: "bed.double", trailingCount: 5, kind: .room, entityId: "room-4"),
                HomeRow(name: "Storage", subtitle: "Delete pending", systemImage: "shippingbox", trailingCount: 2, kind: .room, entityId: "room-5"),
            ]),
            HomeSection(title: "Zones", rows: [
                HomeRow(name: "Upstairs", subtitle: "Living Room, Master Bedroom", systemImage: "house", trailingCount: 2, kind: .zone, entityId: "zone-1"),
                HomeRow(name: "Downstairs", subtitle: "Kitchen, Entry", systemImage: "house", trailingCount: 2, kind: .zone, entityId: "zone-2"),
            ]),
            HomeSection(title: "Scenes", rows: [
                HomeRow(name: "Good Morning", subtitle: "8 actions · 4 accessories", systemImage: "sunrise", kind: .scene, entityId: "scene-1"),
                HomeRow(name: "Goodnight", subtitle: "12 actions · 7 accessories", systemImage: "moon.stars", kind: .scene, entityId: "scene-2"),
                HomeRow(name: "Movie Time", subtitle: "5 actions · 3 accessories", systemImage: "film", kind: .scene, entityId: "scene-3"),
            ]),
            HomeSection(title: "Triggers", rows: [
                HomeRow(name: "Weekday evening", subtitle: "Timer · 17:30 Mon–Fri", systemImage: "clock", kind: .trigger, entityId: "trigger-1"),
                HomeRow(name: "Away lights", subtitle: "Event · presence predicate", systemImage: "location", kind: .trigger, entityId: "trigger-2"),
                HomeRow(name: "Old porch light", subtitle: "Timer · disabled", systemImage: "lightbulb", isEnabled: false, kind: .trigger, entityId: "trigger-3"),
            ]),
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

    /// Presentational: the row disappears; nothing is stored.
    func revokeAgent(_ id: UUID) async {
        pairedAgents.removeAll { $0.id == id }
    }

    func stage(row: HomeRow, action: HomeRowAction, newName: String?) async {
        // Presentational only: append the proposal the swipe would stage so
        // previews can show the queue badge reacting to a Home swipe.
        guard let request = row.stageRequest(for: action, newName: newName) else { return }
        proposals.append(
            NilesProposal(
                id: "prop_swipe_\(proposals.count + 1)",
                tool: request.tool,
                title: "\(action.title) “\(row.name)”",
                agentName: "You",
                createdAt: Date(),
                isDestructive: action == .delete,
                evidence: [],
                diff: []
            )
        )
    }
}
