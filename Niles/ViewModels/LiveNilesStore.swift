import Foundation
import NilesCore
import Observation
import OSLog
import UIKit

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
    /// Optimistic tap feedback: proposal id -> decision whose pipeline
    /// round-trip is still running. Set synchronously in the tap handler,
    /// cleared when the pipeline settles (or the decision fails).
    private(set) var decisionsInFlight: [String: ProposalDecision] = [:]
    /// The activity timeline as of the last refresh, oldest first.
    private(set) var activityEvents: [ActivityEvent] = []

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
    /// Last-seen proposal state per id — the poll diff that turns state
    /// changes into activity events (the store is a snapshot, not a stream).
    private var recordedStates: [String: ProposalState] = [:]
    /// The persistent activity timeline, reloaded from disk at init and
    /// appended to as decisions and state changes happen (see ActivityLog).
    private let activityLog: ActivityLog
    /// The first refresh seeds every proposal already in the store (e.g. ones
    /// staged before a background/foreground cycle) without notifying — only
    /// arrivals after launch get banners.
    private var hasSeededExistingProposals = false
    /// The user's kill switch (spec: the server toggle doubles as one). While
    /// set, foregrounding the app does not restart serving.
    private var userStoppedServer = false
    /// Set from the scene phase handoff in `handleScene(isActive:)`; the keep-
    /// awake policy only holds the screen up while the app is frontmost.
    private var isAppActive = false

    init(
        coordinator: ServerCoordinator,
        notifier: ProposalNotifier,
        tokenStore: any TokenStoring = KeychainTokenStore(),
        pollInterval: Duration = .seconds(1),
        activityLog: ActivityLog? = nil
    ) {
        self.coordinator = coordinator
        self.notifier = notifier
        self.tokenStore = tokenStore
        self.pollInterval = pollInterval
        self.activityLog = activityLog ?? ActivityLog()
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
        isAppActive = isActive
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
        beginDecision(.approving, id: id)
        Task { await approveAndWait(id) }
    }

    func deny(_ id: String) {
        beginDecision(.denying, id: id)
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

    /// Optimistic tap feedback, applied synchronously before the pipeline
    /// task is even spawned: the card's in-progress chip and disabled
    /// buttons render on the next frame and the haptic fires at the tap,
    /// so the pipeline round-trip can never make a tap look dead.
    /// `decide` clears the marker when the pipeline settles or fails.
    private func beginDecision(_ decision: ProposalDecision, id: String) {
        guard proposals.first(where: { $0.id == id })?.isPending == true else { return }
        decisionsInFlight[id] = decision
        let haptic = UINotificationFeedbackGenerator()
        haptic.prepare()
        haptic.notificationOccurred(decision == .approving ? .success : .warning)
    }

    private func decide(approve: Bool, id: String) async {
        guard let store = coordinator.proposalStore else {
            let verb = approve ? "approve" : "deny"
            logger.error("Cannot \(verb, privacy: .public) \(id, privacy: .public): no proposal store")
            decisionsInFlight[id] = nil
            return
        }
        do {
            if approve {
                _ = try await store.approve(id: id)
            } else {
                _ = try await store.deny(id: id)
            }
            await appendActivity(
                .decided,
                proposalId: id,
                title: proposals.first { $0.id == id }?.title ?? id,
                agentName: agentNamesByProposal[id],
                decision: approve ? "approved" : "denied"
            )
        } catch {
            // Terminal-state violations and unknown ids are the expected
            // failures here; the card keeps its staged state either way.
            logger.error("Decision failed for \(id): \(String(describing: error))")
            // The decision did not land — drop the optimistic chip so the
            // card reverts to the store's real state at the next refresh.
            decisionsInFlight[id] = nil
        }
        await refresh()
        // Settled either way: the refreshed state is authoritative.
        decisionsInFlight[id] = nil
    }

    // MARK: - Undo and approve-all

    /// Undoes an executed proposal: its paired revert stages and executes
    /// immediately as a forward-only proposal — the Undo tap IS the
    /// approval. A conflicted revert throws and changes nothing; the card
    /// keeps its executed state at the next refresh.
    func undo(_ id: String) {
        Task { await undoAndWait(id) }
    }

    func undoAndWait(_ id: String) async {
        guard let store = coordinator.proposalStore else {
            logger.error("Cannot undo \(id, privacy: .public): no proposal store")
            return
        }
        do {
            let revert = try await store.undo(proposalId: id)
            await appendActivity(
                .undone,
                proposalId: id,
                title: proposals.first { $0.id == id }?.title ?? id,
                agentName: agentNamesByProposal[id],
                detail: "Reverted — \(revert.title)"
            )
        } catch {
            logger.error("Undo failed for \(id, privacy: .public): \(String(describing: error))")
        }
        await refresh()
    }

    /// Approves and executes every staged proposal immediately —
    /// destructive included. Undo afterwards is per-item, each with its
    /// own conflict check.
    func approveAll() {
        Task { await approveAllAndWait() }
    }

    func approveAllAndWait() async {
        guard let store = coordinator.proposalStore else {
            logger.error("Cannot approve all: no proposal store")
            return
        }
        do {
            let executed = try await store.approveAll()
            for proposal in executed {
                await appendActivity(
                    .decided,
                    proposalId: proposal.id,
                    title: proposals.first { $0.id == proposal.id }?.title ?? proposal.id,
                    agentName: agentNamesByProposal[proposal.id],
                    decision: "approved"
                )
            }
        } catch {
            logger.error("Approve all failed: \(String(describing: error))")
        }
        await refresh()
    }

    // MARK: - PairingViewModel

    func toggleTokenRevealed() {
        isTokenRevealed.toggle()
    }

    // MARK: - HomeGraphViewModel / swipe-to-stage

    /// Stages a Home row's swipe action through the same public store path
    /// the agent write tools use, so the swipe produces a normal proposal in
    /// the queue and nothing touches HomeKit until it is approved.
    func stage(row: HomeRow, action: HomeRowAction, newName: String? = nil) async {
        guard let request = row.stageRequest(for: action, newName: newName) else {
            logger.error("No write tool maps to \(String(describing: action), privacy: .public) on “\(row.name, privacy: .public)”")
            return
        }
        guard let store = coordinator.proposalStore else {
            logger.error("Cannot stage \(request.tool, privacy: .public): no proposal store")
            return
        }
        do {
            let proposal = try await store.stage(tool: request.tool, arguments: request.arguments)
            // A swipe is a human action, not an agent's — attribute it as such
            // before the next refresh fills unknown ids with a client name.
            agentNamesByProposal[proposal.id] = "You"
            await refresh()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            // Staging rejections (validation, HomeKit state) surface here;
            // nothing was applied either way — the queue stays authoritative.
            logger.error("Staging \(request.tool, privacy: .public) for “\(row.name, privacy: .public)” failed: \(String(describing: error))")
        }
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
        applyIdleTimerPolicy()

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
            for proposal in live {
                agentNamesByProposal[proposal.id] = newestClientName(from: sessions)
                // Seed the poll-diff baseline without recording history the
                // log already holds (or that predates this launch).
                recordedStates[proposal.id] = proposal.state
            }
            hasSeededExistingProposals = true
        } else {
            for proposal in live where agentNamesByProposal[proposal.id] == nil {
                agentNamesByProposal[proposal.id] = newestClientName(from: sessions) ?? "MCP agent"
                // A revert proposal is the user's own Undo tap, staged and
                // executed inside one store call — a poll can catch it
                // mid-flight in .staged. It is never an agent arrival:
                // no notification, no staged event.
                if proposal.state == .staged, proposal.revertsProposalId == nil {
                    notifier.proposalArrived(title: proposal.title, summary: proposal.summary)
                    await appendActivity(
                        .staged,
                        proposalId: proposal.id,
                        title: proposal.title,
                        agentName: agentNamesByProposal[proposal.id]
                    )
                }
            }
            // The poll diff: state changes become activity events. Decisions
            // and undos are recorded by their verbs; execution and expiry
            // happen inside the store, so only the next poll can see them.
            for proposal in live {
                let previous = recordedStates[proposal.id]
                recordedStates[proposal.id] = proposal.state
                guard previous != proposal.state else { continue }
                switch proposal.state {
                case .executed, .failed:
                    var detail = Self.executionOutcome(of: proposal) ?? ""
                    if let originalId = proposal.revertsProposalId {
                        let originalTitle = live.first { $0.id == originalId }?.title ?? originalId
                        detail += (detail.isEmpty ? "" : " — ") + "revert of “\(originalTitle)”"
                    }
                    await appendActivity(
                        .executed,
                        proposalId: proposal.id,
                        title: proposal.title,
                        agentName: agentNamesByProposal[proposal.id],
                        detail: detail.isEmpty ? nil : detail,
                        evidence: proposal.evidence
                    )
                case .expired:
                    await appendActivity(
                        .expired,
                        proposalId: proposal.id,
                        title: proposal.title,
                        agentName: agentNamesByProposal[proposal.id],
                        detail: "Expired after 24 hours — never executed"
                    )
                case .staged, .approved, .denied:
                    break
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
        activityEvents = await activityLog.allEvents()

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

    /// Appends one event to the persistent activity log and mirrors it into
    /// `activityEvents`. Append failures are logged by the log itself, never
    /// thrown — the timeline must not take a decision down with it.
    private func appendActivity(
        _ kind: ActivityEvent.Kind,
        proposalId: String,
        title: String,
        agentName: String?,
        decision: String? = nil,
        detail: String? = nil,
        evidence: [ProposalEvidence] = []
    ) async {
        await activityLog.append(ActivityEvent(
            at: Date(),
            kind: kind,
            proposalId: proposalId,
            proposalTitle: title,
            agentName: agentName,
            decision: decision,
            detail: detail,
            evidence: evidence
        ))
        activityEvents = await activityLog.allEvents()
    }

    /// The `.executed` event's outcome line: the read-back tally when the
    /// operations ran, the recorded HomeKit error when they failed mid-list.
    private static func executionOutcome(of proposal: Proposal) -> String? {
        if let error = proposal.error { return "Failed — \(error)" }
        let confirmed = proposal.evidence.filter(\.confirmed).count
        return "\(confirmed) of \(proposal.evidence.count) checks confirmed"
    }

    /// Serving keeps the screen awake (a locked phone suspends the LAN
    /// server); stopping the server or backgrounding restores normal auto-lock.
    private func applyIdleTimerPolicy() {
        UIApplication.shared.isIdleTimerDisabled = IdleTimerPolicy.shouldKeepScreenAwake(
            isServing: serverIsRunning,
            isAppActive: isAppActive
        )
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
        // Context lines are the card's own notes; read-back evidence rides
        // on NilesProposal.evidence in its structured form — no more "✓ …"
        // strings glued into prose.
        var context: [ProposalDiffLine] = proposal.card
            .filter { $0.kind == .note || $0.kind == .plain }
            .map { ProposalDiffLine(ProposalDiffLine.Kind($0.kind), $0.text) }
        if let error = proposal.error {
            context.append(ProposalDiffLine(.note, "⚠ HomeKit error: \(error)"))
        }

        return NilesProposal(
            id: proposal.id,
            tool: proposal.tool,
            title: proposal.title,
            agentName: agentName,
            createdAt: proposal.createdAt,
            isDestructive: proposal.isDestructive,
            evidence: proposal.evidence,
            diff: proposal.card
                .filter { $0.kind == .add || $0.kind == .remove }
                .map { ProposalDiffLine(ProposalDiffLine.Kind($0.kind), $0.text) },
            context: context,
            state: proposal.state,
            revertsProposalId: proposal.revertsProposalId
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
                    trailingCount: room.accessories.count,
                    kind: .room,
                    entityId: room.id
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
                    trailingCount: names.count,
                    kind: .zone,
                    entityId: zone.id
                )
            }),
            HomeSection(title: "Scenes", rows: (home?.scenes ?? []).map { scene in
                let accessories = Set(scene.actions.compactMap(\.accessoryId)).count
                return HomeRow(
                    name: scene.name,
                    subtitle: "\(scene.actions.count) actions · \(accessories) accessories",
                    systemImage: "film",
                    trailingCount: scene.actions.count,
                    kind: .scene,
                    entityId: scene.id
                )
            }),
            HomeSection(title: "Triggers", rows: (home?.triggers ?? []).map { trigger in
                HomeRow(
                    name: trigger.name,
                    subtitle: Self.subtitle(for: trigger.detail),
                    systemImage: "clock",
                    isEnabled: trigger.isEnabled,
                    kind: .trigger,
                    entityId: trigger.id
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
