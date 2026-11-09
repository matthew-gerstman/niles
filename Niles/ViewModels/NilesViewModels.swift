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
protocol ApprovalsViewModel: Observable {
    var proposals: [NilesProposal] { get }
    /// Proposal id -> decision in flight; present from the tap until the
    /// pipeline settles (or the decision fails and the card reverts).
    var decisionsInFlight: [String: ProposalDecision] { get }
    func approve(_ id: String)
    func deny(_ id: String)
}

/// The direction of a decision whose pipeline round-trip is still running.
/// Cards render an in-progress chip and disable their buttons until it
/// settles, so a tap never looks dead while the pipeline works.
enum ProposalDecision: Hashable {
    case approving
    case denying
}

@MainActor
protocol HomeGraphViewModel: Observable {
    var sections: [HomeSection] { get }
    /// Stages a row's swipe action through the same proposal pipeline agents
    /// use — the proposal lands in the queue and nothing applies until the
    /// human approves it. Failures are logged, never applied.
    func stage(row: HomeRow, action: HomeRowAction, newName: String?) async
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
final class InMemoryNilesStore: DashboardViewModel, ApprovalsViewModel, HomeGraphViewModel, PairingViewModel {
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
        ]

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

    private func decide(_ id: String, to next: ProposalState) {
        guard let index = proposals.firstIndex(where: { $0.id == id }),
              proposals[index].state.canTransition(to: next) else { return }
        proposals[index].state = next
    }

    func toggleTokenRevealed() {
        isTokenRevealed.toggle()
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
                evidence: "",
                diff: []
            )
        )
    }
}
