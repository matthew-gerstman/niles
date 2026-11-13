import Foundation
import NilesCore
import Observation
import OSLog

/// The composition root the app and both Siri entry points share. A
/// background App Intent launches the app process without foregrounding the
/// UI, so the Siri entry point and the app's screens must observe the same
/// stores — one instance, built here and handed to `NilesApp` as its state.
///
/// Cleanup W3 decomposed the former monolithic store into focused stores
/// along its protocol seams; each screen observes its own seam's store:
/// - `LiveDashboardStore` — serving status, endpoint, connected agents,
///   the server kill switch, and the keep-awake policy
/// - `LiveQueueStore` — the decision pipeline and the activity timeline
///   (`QueueViewModel` + `ActivityViewModel`: one pipeline, two windows)
/// - `LiveHomeGraphStore` — read-only home sections and swipe-to-stage
/// - `LivePairingStore` — the pairing code, paired credentials, revocation
///
/// The proposal store is an actor with no change callbacks, so the poll
/// loop here fans out on a short interval: `refresh()` pulls one consistent
/// view from the coordinator, proposal store, and graph — in one order,
/// with the poll-diff bookkeeping (`recordedStates`, agent attribution)
/// kept here where the single synchronous scan needs it — and applies it
/// to the stores. Every read is in-memory and cheap.
@MainActor
@Observable
final class LiveNilesStore {

    // MARK: - Focused stores

    let dashboard: LiveDashboardStore
    let queue: LiveQueueStore
    let homeGraph: LiveHomeGraphStore
    let pairing: LivePairingStore

    // MARK: - Engine

    /// Internal, not private: the simulator QA fixtures live in an
    /// extension over this type in another file and drive the coordinator
    /// and the log directly (they were private methods of the monolith).
    let coordinator: ServerCoordinator
    private let notifier: ProposalNotifier
    private let pollInterval: Duration
    let logger = Logger(subsystem: "com.gerstman.niles", category: "live-store")

    private var pollingTask: Task<Void, Never>?
    /// Last-seen proposal state per id — the poll diff that turns state
    /// changes into activity events (the store is a snapshot, not a stream).
    private var recordedStates: [String: ProposalState] = [:]
    /// Proposal id -> the agent that staged it, attributed from the newest
    /// session at detection time. In-memory only, like the proposal store.
    private(set) var agentNamesByProposal: [String: String] = [:]
    /// The first refresh seeds every proposal already in the store (e.g. ones
    /// staged before a background/foreground cycle) without notifying — only
    /// arrivals after launch get banners.
    private var hasSeededExistingProposals = false

    init(
        coordinator: ServerCoordinator,
        notifier: ProposalNotifier,
        tokenStore: any TokenStoring = KeychainTokenStore(),
        pollInterval: Duration = .seconds(1),
        activityLog: ActivityLog? = nil
    ) {
        self.coordinator = coordinator
        self.notifier = notifier
        self.pollInterval = pollInterval
        let activityLog = activityLog ?? ActivityLog()

        let queue = LiveQueueStore(coordinator: coordinator, activityLog: activityLog)
        self.queue = queue
        self.dashboard = LiveDashboardStore(coordinator: coordinator)
        self.homeGraph = LiveHomeGraphStore(coordinator: coordinator)
        self.pairing = LivePairingStore(coordinator: coordinator, tokenStore: tokenStore)

        // Fully initialized: wire the stores' weak back-references to the
        // poll loop before anything can run.
        dashboard.root = self
        queue.root = self
        homeGraph.root = self
    }

    // MARK: - Lifecycle

    /// Begins polling. Idempotent.
    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: self?.pollInterval ?? .seconds(1))
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Scene-phase handoff from the app entry: active means serving only
    /// with recorded consent (the first-open approval, `mayAutoServe`), and
    /// never over the user's kill switch; anything else stops the server.
    func handleScene(isActive: Bool) async {
        dashboard.applySceneActive(isActive)
        if isActive {
            // Before anything can stage, decide, or even poll: revalidate
            // what the launch loaded from disk, so the queue's first render
            // already reflects the live home.
            await coordinator.revalidateProposals()
            // One gate covers both the socket and Bonjour: LANServer.start()
            // binds the port and registers `_niles-mcp._tcp` atomically. An
            // unanswered or denied consent means nothing binds on open — the
            // first-open sheet's Approve is the user action that starts it.
            if dashboard.mayAutoServe {
                await coordinator.start()
            }
            start()
        } else {
            stop()
            await coordinator.stop()
        }
        await refresh()
    }

    // MARK: - Refresh

    /// Pulls one consistent view from the coordinator, proposal store, and
    /// graph, fanning out to the focused stores in the same order the
    /// monolithic store used. Read failures keep the previous content and
    /// are logged — a transient snapshot error must not blank the screens.
    func refresh() async {
        dashboard.applyServerState()

        let sessions = await coordinator.sessionInfos()
        dashboard.applySessions(sessions)
        await pairing.refreshState(sessions: sessions)

        guard let store = coordinator.proposalStore else { return }
        let live = await store.allProposals()

        if !hasSeededExistingProposals {
            for proposal in live {
                agentNamesByProposal[proposal.id] = newestClientName(from: sessions)
                // Seed the poll-diff baseline without recording history the
                // log already holds (or that predates this launch).
                recordedStates[proposal.id] = proposal.state
            }
            // Proposals the load-time sweep expired: their expiry happened
            // while the app was dead, so no poll ever saw the transition —
            // record the event now, stamped with this launch instant.
            for proposal in await store.takeProposalsExpiredAtLoad() {
                await queue.appendActivity(
                    .expired,
                    proposalId: proposal.id,
                    title: proposal.title,
                    agentName: nil,
                    detail: "Expired after 24 hours — never executed"
                )
            }
            hasSeededExistingProposals = true
        } else {
            // One synchronous scan: every first-seen and state transition is
            // recorded and its event collected BEFORE any await. Concurrent
            // refreshes interleave at await points; a scan that suspends
            // mid-way lets a second pass see the same proposals as
            // first-seen and announce them twice.
            var arrivals: [Proposal] = []
            var executedTransitions: [Proposal] = []
            var expiredTransitions: [Proposal] = []
            for proposal in live {
                let previous = recordedStates[proposal.id]
                recordedStates[proposal.id] = proposal.state
                if agentNamesByProposal[proposal.id] == nil {
                    agentNamesByProposal[proposal.id] = newestClientName(from: sessions) ?? "MCP agent"
                }
                // A revert proposal is the user's own Undo tap, staged and
                // executed inside one store call — a poll can catch it
                // mid-flight in .staged. It is never an agent arrival:
                // no notification, no staged event.
                if previous == nil, proposal.state == .staged, proposal.revertsProposalId == nil {
                    arrivals.append(proposal)
                }
                // Decisions and undos are recorded by their verbs; execution
                // and expiry happen inside the store, so only a later poll
                // can see the transition. A proposal first seen already in a
                // terminal state has no observable transition here.
                guard previous != nil, previous != proposal.state else { continue }
                switch proposal.state {
                case .executed, .failed:
                    executedTransitions.append(proposal)
                case .expired:
                    expiredTransitions.append(proposal)
                case .staged, .approved, .denied:
                    break
                }
            }
            for proposal in arrivals {
                notifier.proposalArrived(title: proposal.title, summary: proposal.summary)
                await queue.appendActivity(
                    .staged,
                    proposalId: proposal.id,
                    title: proposal.title,
                    agentName: agentNamesByProposal[proposal.id]
                )
            }
            for proposal in executedTransitions {
                var detail = Self.executionOutcome(of: proposal) ?? ""
                if let originalId = proposal.revertsProposalId {
                    let originalTitle = live.first { $0.id == originalId }?.title ?? originalId
                    detail += (detail.isEmpty ? "" : " — ") + "revert of “\(originalTitle)”"
                }
                await queue.appendActivity(
                    .executed,
                    proposalId: proposal.id,
                    title: proposal.title,
                    agentName: agentNamesByProposal[proposal.id],
                    detail: detail.isEmpty ? nil : detail,
                    evidence: proposal.evidence
                )
            }
            for proposal in expiredTransitions {
                await queue.appendActivity(
                    .expired,
                    proposalId: proposal.id,
                    title: proposal.title,
                    agentName: agentNamesByProposal[proposal.id],
                    detail: "Expired after 24 hours — never executed"
                )
            }
        }

        queue.applyProposals(live.map { proposal in
            // Screenshot-fixture freeze: the frozen row's planted state has
            // no live counterpart in the proposal store, so the poll must
            // not remap it out from under the capture.
            if queue.frozenProposalIds.contains(proposal.id),
               let frozen = queue.proposals.first(where: { $0.id == proposal.id }) {
                return frozen
            }
            return Self.uiProposal(
                for: proposal,
                agentName: agentNamesByProposal[proposal.id] ?? "MCP agent"
            )
        })
        await queue.reloadActivity()

        do {
            let graph = try await store.homeKit.snapshot()
            homeGraph.applySections(Self.sections(from: graph))
            if let first = graph.homes.first {
                dashboard.applyHomeName(first.name)
            }
        } catch {
            logger.error("Home graph read failed, keeping previous sections: \(String(describing: error))")
        }
    }

    // MARK: - Shared poll bookkeeping (read by the focused stores)

    /// The agent a proposal is attributed to, as recorded at detection time.
    func agentName(for proposalId: String) -> String? {
        agentNamesByProposal[proposalId]
    }

    /// Attributes a human action before the next refresh fills unknown ids
    /// with a client name.
    func setAgentName(_ name: String, for proposalId: String) {
        agentNamesByProposal[proposalId] = name
    }

    private func newestClientName(from sessions: [MCPGateway.SessionInfo]) -> String? {
        sessions.max { $0.startedAt < $1.startedAt }?.clientName
    }

    /// The `.executed` event's outcome line: the read-back tally when the
    /// operations ran, the recorded HomeKit error when they failed mid-list.
    private static func executionOutcome(of proposal: Proposal) -> String? {
        if let error = proposal.error { return "Failed — \(error)" }
        let confirmed = proposal.evidence.filter(\.confirmed).count
        return "\(confirmed) of \(proposal.evidence.count) checks confirmed"
    }

    // MARK: - Live -> UI mapping

    private static func uiProposal(for proposal: Proposal, agentName: String) -> NilesProposal {
        // The card in its original order is the single source of change
        // order: batches carry one banner line per operation followed by
        // that operation's lines, and the detail sheet groups on exactly
        // that sequence. diff/context remain derived views of the same
        // lines — the queue row's summary and evidence inputs — never an
        // ordering source again (the old split scrambled batch order).
        var changes: [ProposalDiffLine] = proposal.card
            .map { ProposalDiffLine(ProposalDiffLine.Kind($0.kind), $0.text) }
        if let error = proposal.error {
            // A still-staged proposal's error is the launch revalidation's
            // missing-target flag, not an execution failure — label it as
            // what it is, and surface it on the queue row too.
            let prefix = proposal.state == .staged ? "⚠ " : "⚠ HomeKit error: "
            changes.append(ProposalDiffLine(.note, "\(prefix)\(error)"))
        }

        return NilesProposal(
            id: proposal.id,
            tool: proposal.tool,
            title: proposal.title,
            agentName: agentName,
            createdAt: proposal.createdAt,
            isDestructive: proposal.isDestructive,
            evidence: proposal.evidence,
            diff: changes.filter { $0.kind == .add || $0.kind == .remove },
            context: changes.filter { $0.kind == .note || $0.kind == .plain },
            changes: changes,
            staleReason: proposal.state == .staged ? proposal.error : nil,
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
        case .event(let event):
            let readableSuffix = event.readable ? "" : " · parts unreadable"
            let predicateSuffix = event.predicate.map { " · \($0)" } ?? ""
            return "Event · \(event.events.count) event\(event.events.count == 1 ? "" : "s")\(predicateSuffix)\(readableSuffix)"
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
