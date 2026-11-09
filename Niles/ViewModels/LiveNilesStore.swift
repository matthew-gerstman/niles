import Foundation
import NilesCore
import Observation
import OSLog

/// A `HomeKitWriting` backed by the real home database.
///
/// Reads and writes both run on `HomeManagerHomeKitService`: the actor owns
/// the `HMHomeManager` and executes approved operations against it through
/// the resolver + continuation executor (spec: write execution).
struct DeviceHomeKitService: HomeKitWriting {
    private let reader = HomeManagerHomeKitService()

    func snapshot() async throws -> HomeGraph {
        try await reader.snapshot()
    }

    func perform(_ operation: HomeKitOperation) async throws -> String? {
        try await reader.perform(operation)
    }
}

/// The live store behind all four screens, replacing `InMemoryNilesStore`'s
/// fixture wiring with the real pipeline, transport, and Keychain.
///
/// Every screen keeps observing the same view-model protocols from the
/// screens PR; this class fills them from:
/// - `ServerCoordinator` — server status, endpoint, connected MCP sessions
/// - `ProposalStore` — staged proposals, approval/denial, read-back evidence
/// - `KeychainTokenStore` — the same 256-bit bearer token the transport gates with
/// - the HomeKit service's graph — the read-only home sections
///
/// The proposal store is an actor with no change callbacks, so the store
/// polls on a short interval; every read is in-memory and cheap.
@MainActor
@Observable
final class LiveNilesStore: DashboardViewModel, ApprovalsViewModel, HomeGraphViewModel, PairingViewModel {

    // MARK: - DashboardViewModel

    private(set) var homeName = "No home"
    private(set) var serverIsRunning = false
    private(set) var endpoint = ""
    private(set) var bonjourService = "\(NilesBonjour.serviceType).local"
    private(set) var sessionsSummary = "0 active"
    private(set) var approvedTodayCount = 0
    private(set) var connectedAgents: [AgentConnection] = []

    // MARK: - ApprovalsViewModel

    private(set) var proposals: [NilesProposal] = []

    // MARK: - HomeGraphViewModel

    private(set) var sections: [HomeSection] = []

    // MARK: - PairingViewModel

    let transportName = "Streamable HTTP"
    private(set) var token = ""
    private(set) var tokenError: String?
    private(set) var isTokenRevealed = false
    private(set) var trustedAgents: [AgentConnection] = []

    var pendingProposals: [NilesProposal] {
        proposals.filter(\.isPending)
    }

    private let coordinator: ServerCoordinator
    private let notifier: ProposalNotifier
    private let tokenStore: any TokenStoring
    private let pollInterval: Duration
    private let logger = Logger(subsystem: "com.gerstman.niles", category: "live-store")

    private var pollingTask: Task<Void, Never>?
    /// Proposal id -> the agent that staged it, attributed from the newest
    /// session at detection time. In-memory only, like the proposal store.
    private var agentNamesByProposal: [String: String] = [:]
    /// The first refresh seeds every proposal already in the store (e.g. ones
    /// staged before a background/foreground cycle) without notifying — only
    /// arrivals after launch get banners.
    private var hasSeededExistingProposals = false
    /// The user's kill switch (spec: the server toggle doubles as one). While
    /// set, foregrounding the app does not restart serving.
    private var userStoppedServer = false

    init(
        coordinator: ServerCoordinator,
        notifier: ProposalNotifier,
        tokenStore: any TokenStoring = KeychainTokenStore(),
        pollInterval: Duration = .seconds(1)
    ) {
        self.coordinator = coordinator
        self.notifier = notifier
        self.tokenStore = tokenStore
        self.pollInterval = pollInterval
        let host = LANAddress.primaryIPv4 ?? "127.0.0.1"
        endpoint = "http://\(host):\(LANServer.defaultPort)/mcp"
    }

    // MARK: - Lifecycle

    /// Begins polling and loads the Keychain token. Idempotent.
    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(1))
            }
        }
        Task { await loadToken() }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Scene-phase handoff from the app entry: active means serving unless
    /// the user's kill switch is on; anything else stops the server.
    func handleScene(isActive: Bool) async {
        if isActive {
            start()
            if !userStoppedServer {
                await coordinator.start()
            }
        } else {
            stop()
            await coordinator.stop()
        }
        await refresh()
    }

    // MARK: - DashboardViewModel / scene-phase wiring

    /// The server toggle's kill switch: off closes every connection and
    /// unregisters Bonjour; on resumes serving while foregrounded.
    func setServerRunning(_ running: Bool) {
        userStoppedServer = !running
        serverIsRunning = running
        Task {
            if running {
                await coordinator.start()
            } else {
                await coordinator.stop()
            }
            await refresh()
        }
    }

    // MARK: - ApprovalsViewModel

    /// Approves and executes the staged operations; the result (state,
    /// evidence, error) appears on the card at the next refresh.
    func approve(_ id: String) {
        Task { await approveAndWait(id) }
    }

    func deny(_ id: String) {
        Task { await denyAndWait(id) }
    }

    /// Awaitable decision path — what the button handlers spawn; tests and
    /// this store's own tasks await it directly.
    func approveAndWait(_ id: String) async {
        await decide(approve: true, id: id)
    }

    func denyAndWait(_ id: String) async {
        await decide(approve: false, id: id)
    }

    private func decide(approve: Bool, id: String) async {
        guard let store = coordinator.proposalStore else {
            let verb = approve ? "approve" : "deny"
            logger.error("Cannot \(verb, privacy: .public) \(id, privacy: .public): no proposal store")
            return
        }
        do {
            if approve {
                _ = try await store.approve(id: id)
            } else {
                _ = try await store.deny(id: id)
            }
        } catch {
            // Terminal-state violations and unknown ids are the expected
            // failures here; the card keeps its staged state either way.
            logger.error("Decision failed for \(id): \(String(describing: error))")
        }
        await refresh()
    }

    // MARK: - PairingViewModel

    func toggleTokenRevealed() {
        isTokenRevealed.toggle()
    }

    /// Awaitable token load — the polling task calls this once at start;
    /// tests call it directly.
    func loadTokenAndWait() async {
        await loadToken()
    }

    // MARK: - Refresh

    /// Pulls one consistent view from the coordinator, proposal store, and
    /// graph. Read failures keep the previous content and are logged — a
    /// transient snapshot error must not blank the screens.
    func refresh() async {
        endpoint = "http://\(LANAddress.primaryIPv4 ?? "127.0.0.1"):\(LANServer.defaultPort)/mcp"
        serverIsRunning = coordinator.status.isRunning

        let sessions = await coordinator.sessionInfos()
        sessionsSummary = "\(sessions.count) active"
        connectedAgents = sessions.map { session in
            AgentConnection(
                name: session.clientName ?? "Unknown client",
                detail: "Streamable HTTP · last seen \(RelativeTime.label(for: session.lastAccessedAt))",
                isActive: Date().timeIntervalSince(session.lastAccessedAt) < 30
            )
        }
        trustedAgents = connectedAgents

        guard let store = coordinator.proposalStore else { return }
        let live = await store.allProposals()

        if !hasSeededExistingProposals {
            for proposal in live { agentNamesByProposal[proposal.id] = newestClientName(from: sessions) }
            hasSeededExistingProposals = true
        } else {
            for proposal in live where agentNamesByProposal[proposal.id] == nil {
                agentNamesByProposal[proposal.id] = newestClientName(from: sessions) ?? "MCP agent"
                if proposal.state == .staged {
                    notifier.proposalArrived(title: proposal.title, summary: proposal.summary)
                }
            }
        }

        proposals = live.map { proposal in
            Self.uiProposal(
                for: proposal,
                agentName: agentNamesByProposal[proposal.id] ?? "MCP agent"
            )
        }
        approvedTodayCount = live.filter {
            $0.state == .executed && Calendar.current.isDateInToday($0.createdAt)
        }.count

        do {
            let graph = try await store.homeKit.snapshot()
            sections = Self.sections(from: graph)
            if let first = graph.homes.first {
                homeName = first.name
            }
        } catch {
            logger.error("Home graph read failed, keeping previous sections: \(String(describing: error))")
        }
    }

    private func newestClientName(from sessions: [MCPGateway.SessionInfo]) -> String? {
        sessions.max { $0.startedAt < $1.startedAt }?.clientName
    }

    private func loadToken() async {
        do {
            token = try tokenStore.loadOrCreate()
            tokenError = nil
        } catch {
            // The Keychain is the token's only home; surfacing the failure is
            // better than an empty QR the agent could never pair with.
            token = ""
            tokenError = "Could not read or create the Keychain token: \(error)"
            logger.error("Token load failed: \(String(describing: error))")
        }
    }

    // MARK: - Live -> UI mapping

    private static func uiProposal(for proposal: Proposal, agentName: String) -> NilesProposal {
        var context: [ProposalDiffLine] = proposal.card
            .filter { $0.kind == .note || $0.kind == .plain }
            .map { ProposalDiffLine(ProposalDiffLine.Kind($0.kind), $0.text) }
        for item in proposal.evidence {
            let mark = item.confirmed ? "✓" : "✗"
            context.append(ProposalDiffLine(.plain, "\(mark) \(item.claim) — \(item.observed)"))
        }
        if let error = proposal.error {
            context.append(ProposalDiffLine(.note, "⚠ HomeKit error: \(error)"))
        }

        let evidence: String
        if proposal.evidence.isEmpty {
            evidence = "After approval, Niles re-reads the home from HomeKit and attaches the read-back "
                + "evidence here. Denied and expired proposals never run anything."
        } else {
            let confirmed = proposal.evidence.filter(\.confirmed).count
            evidence = "Read-back evidence: \(confirmed) of \(proposal.evidence.count) checks confirmed "
                + "against the live home."
        }

        return NilesProposal(
            id: proposal.id,
            tool: proposal.tool,
            title: proposal.title,
            agentName: agentName,
            createdAt: proposal.createdAt,
            isDestructive: proposal.isDestructive,
            evidence: evidence,
            diff: proposal.card
                .filter { $0.kind == .add || $0.kind == .remove }
                .map { ProposalDiffLine(ProposalDiffLine.Kind($0.kind), $0.text) },
            context: context,
            state: proposal.state
        )
    }

    private static func sections(from graph: HomeGraph) -> [HomeSection] {
        let home = graph.homes.first
        let zoneByRoom = Dictionary(
            home?.zones.flatMap { zone in zone.roomIds.map { ($0, zone.name) } } ?? [],
            uniquingKeysWith: { first, _ in first }
        )
        return [
            HomeSection(title: "Rooms", rows: (home?.rooms ?? []).map { room in
                HomeRow(
                    name: room.name,
                    subtitle: zoneByRoom[room.id] ?? "No zone",
                    systemImage: "table.furniture",
                    trailingCount: room.accessories.count
                )
            }),
            HomeSection(title: "Zones", rows: (home?.zones ?? []).map { zone in
                let names = zone.roomIds.compactMap { id in
                    home?.rooms.first(where: { $0.id == id })?.name
                }
                return HomeRow(
                    name: zone.name,
                    subtitle: names.isEmpty ? "No rooms" : names.joined(separator: ", "),
                    systemImage: "house",
                    trailingCount: names.count
                )
            }),
            HomeSection(title: "Scenes", rows: (home?.scenes ?? []).map { scene in
                let accessories = Set(scene.actions.compactMap(\.accessoryId)).count
                return HomeRow(
                    name: scene.name,
                    subtitle: "\(scene.actions.count) actions · \(accessories) accessories",
                    systemImage: "film",
                    trailingCount: scene.actions.count
                )
            }),
            HomeSection(title: "Triggers", rows: (home?.triggers ?? []).map { trigger in
                HomeRow(
                    name: trigger.name,
                    subtitle: Self.subtitle(for: trigger.detail),
                    systemImage: "clock",
                    isEnabled: trigger.isEnabled
                )
            }),
        ]
    }

    private static func subtitle(for detail: HomeGraph.Trigger.Detail) -> String {
        switch detail {
        case .timer(let fireDate, let recurrence):
            let time = fireDate.formatted(date: .omitted, time: .shortened)
            if recurrence.isEmpty { return "Timer · \(time)" }
            var parts: [String] = []
            if let weekday = recurrence["weekday"] { parts.append(Self.weekdayLetter(for: weekday)) }
            if let hour = recurrence["hour"], let minute = recurrence["minute"] {
                parts.append(String(format: "%02d:%02d", hour, minute))
            }
            let schedule = parts.joined(separator: " ")
            return schedule.isEmpty ? "Timer · \(time)" : "Timer · \(schedule)"
        case .event(let events, let predicate):
            return "Event · \(events.count) event\(events.count == 1 ? "" : "s")\(predicate.map { " · \($0)" } ?? "")"
        case .unknown(let kind):
            return "\(kind) · unsupported trigger kind"
        }
    }

    /// Recurrence values are named DateComponents (`weekday` is 1=Sunday…);
    /// one letter per day keeps the subtitle compact.
    private static func weekdayLetter(for weekday: Int) -> String {
        ["S", "M", "T", "W", "T", "F", "S"][max(0, min(6, weekday - 1))]
    }
}

extension ProposalDiffLine.Kind {
    init(_ kind: ProposalCardLine.Kind) {
        switch kind {
        case .add: self = .add
        case .remove: self = .remove
        case .note: self = .note
        case .plain: self = .plain
        }
    }
}

extension ServerCoordinator.Status {
    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}
