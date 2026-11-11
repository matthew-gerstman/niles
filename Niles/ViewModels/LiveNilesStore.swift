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
/// - `ServerCoordinator` — server status, endpoint, connected MCP sessions,
///   and the shared pairing-code lifecycle
/// - `ProposalStore` — staged proposals, approval/denial, read-back evidence
/// - `KeychainTokenStore` — the paired credentials the transport gates with
/// - the HomeKit service's graph — the read-only home sections
///
/// The proposal store is an actor with no change callbacks, so the store
/// polls on a short interval; every read is in-memory and cheap.
@MainActor
@Observable
final class LiveNilesStore: DashboardViewModel, QueueViewModel, ActivityViewModel, HomeGraphViewModel, PairingViewModel, AgentStatusViewModel, ChatViewModel {

    // MARK: - DashboardViewModel

    private(set) var homeName = "No home"
    private(set) var serverIsRunning = false
    private(set) var endpoint = ""
    private(set) var bonjourService = "\(NilesBonjour.serviceType).local"
    private(set) var sessionsSummary = "0 active"
    private(set) var connectedAgents: [AgentConnection] = []

    // MARK: - QueueViewModel

    private(set) var proposals: [NilesProposal] = []
    /// Optimistic tap feedback: proposal id -> decision whose pipeline
    /// round-trip is still running. Set synchronously in the tap handler,
    /// cleared when the pipeline settles (or the decision fails).
    private(set) var decisionsInFlight: [String: ProposalDecision] = [:]
    /// The activity timeline as of the last refresh, oldest first.
    private(set) var activityEvents: [ActivityEvent] = []
    /// True from the Approve-all tap until the whole batch settles — the
    /// batch button shows progress and cannot re-enter.
    private(set) var isApprovingAll = false
    /// Undo bookkeeping (Queue): per-row divergences recorded from the
    /// store's typed `undoConflict`, rows the store refused with
    /// `notRevertable`, and taps whose revert is still running. All
    /// in-memory, like the proposals themselves.
    private var undoConflicts: [String: [ProposalEvidence]] = [:]
    private var notRevertableIds: Set<String> = []
    private var undosInFlight: Set<String> = []
    /// Undo failures from each proposal's most recent tap, surfaced inline on
    /// the activity card until the next attempt or dismissal.
    private(set) var undoFailures: [String: ActivityUndoFailure] = [:]

    // MARK: - HomeGraphViewModel

    private(set) var sections: [HomeSection] = []

    // MARK: - PairingViewModel

    let transportName = "Streamable HTTP"
    /// The live six-digit code, or `nil` between mint failures. Auto-minted
    /// whenever refresh finds none — after expiry, a successful exchange, or
    /// an attempt-cap burn — so the card always shows a fresh challenge.
    private(set) var pairingCode: String?
    private(set) var codeExpiresAt: Date?
    private(set) var pairedAgents: [PairedAgentRow] = []

    var pendingProposals: [NilesProposal] {
        proposals.filter(\.isPending)
    }

    // MARK: - AgentStatusViewModel

    /// Evaluated once at feature entry (spec art_VrC0iUUA §Availability
    /// gate): the agent is either fully available or states why not — never
    /// a degraded mode.
    private(set) var agentAvailability = AgentAvailability.unavailable(.needsIOS27)
    /// Session usage, refreshed with the poll from the runner when one
    /// exists. Zero until the first request runs.
    private(set) var agentUsage = AgentSessionUsage()
    /// The on-device agent's runner, non-nil only when the gate passed. No
    /// agent path is enterable when this is nil — Settings states the
    /// reason instead.
    private(set) var agentRunner: (any AgentRunning)?

    // MARK: - ChatViewModel

    /// The in-app chat transcript, oldest first (spec art_AL0RolQe).
    /// Session-scoped by design: no durable chat log in v1 — durable
    /// outcomes already live in Queue + Activity.
    private(set) var entries: [ChatEntry] = []
    /// Set from the send until the run resolves — the in-flight half of
    /// `canSend`, so the composer disables and a concurrent send is ignored.
    private(set) var isChatRunInFlight = false

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
        activityLog: ActivityLog? = nil,
        agentRunner: (any AgentRunning)? = nil,
        agentAvailability: AgentAvailability? = nil
    ) {
        self.coordinator = coordinator
        self.notifier = notifier
        self.tokenStore = tokenStore
        self.pollInterval = pollInterval
        self.activityLog = activityLog ?? ActivityLog()
        let host = LANAddress.primaryIPv4 ?? "127.0.0.1"
        endpoint = "http://\(host):\(LANServer.defaultPort)/mcp"

        // Test seams: an injected runner is available by definition (chat
        // tests drive the live store without Apple Intelligence hardware);
        // production callers take the defaults and the gate decides.
        if let injected = agentAvailability {
            self.agentAvailability = injected
        } else if agentRunner != nil {
            self.agentAvailability = .available
        } else {
            self.agentAvailability = Self.evaluateAgentAvailability()
        }
        if let runner = agentRunner {
            self.agentRunner = runner
        } else if case .available = self.agentAvailability,
                  #available(iOS 27.0, *),
                  let proposalStore = coordinator.proposalStore {
            self.agentRunner = AgentService(store: proposalStore)
        }
    }

    /// The one availability check, at the one feature entry this app has.
    /// The gate itself is iOS 26+ (Foundation Models); below that the OS
    /// bar already fails the agent core's iOS 27 requirement.
    private static func evaluateAgentAvailability() -> AgentAvailability {
        if #available(iOS 26.0, *) {
            return AgentAvailabilityGate.evaluate()
        }
        return .unavailable(.needsIOS27)
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

    // MARK: - QueueViewModel

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
    /// approval. A conflicted revert throws and changes nothing; the row
    /// renders the typed `undoConflict` divergences inline until the next
    /// undo attempt on that row. A `notRevertable` refusal stops the row
    /// from offering Undo at all.
    func undo(_ id: String) {
        // Optimistic tap feedback, synchronous like the decision taps: the
        // row's Undoing… state renders before the pipeline task runs.
        guard let proposal = proposals.first(where: { $0.id == id }),
              Self.undoAvailable(for: proposal, proposals: proposals) else { return }
        undosInFlight.insert(id)
        undoConflicts[id] = nil
        Task { await undoAndWait(id) }
    }

    func undoAndWait(_ id: String) async {
        guard let store = coordinator.proposalStore else {
            logger.error("Cannot undo \(id, privacy: .public): no proposal store")
            return
        }
        undosInFlight.insert(id)
        undoConflicts[id] = nil
        defer { undosInFlight.remove(id) }
        // A fresh tap clears the last failure before it runs.
        undoFailures[id] = nil
        do {
            let revert = try await store.undo(proposalId: id)
            await appendActivity(
                .undone,
                proposalId: id,
                title: proposals.first { $0.id == id }?.title ?? id,
                agentName: agentNamesByProposal[id],
                detail: "Reverted — \(revert.title)"
            )
        } catch let error as ProposalStoreError {
            switch error {
            case .undoConflict(_, let divergences):
                // The home diverged from what execution produced. Nothing
                // was applied; the row names the divergence inline.
                undoConflicts[id] = divergences
            case .notRevertable:
                // No paired revert exists (unrevertable operation, lost undo
                // coverage, or a spent plan): the affordance goes away.
                notRevertableIds.insert(id)
            case .proposalNotFound, .proposalNotPending, .homeReadFailed:
                logger.error("Undo failed for \(id, privacy: .public): \(String(describing: error))")
            case .unknownTool, .invalidArguments, .validationFailed:
                // Unreachable from undo — staging errors surface to agents,
                // not to this tap path. Never silently swallowed: logged.
                logger.error("Undo failed for \(id, privacy: .public): \(String(describing: error))")
            }
            // The typed failure surfaces inline on the activity card too —
            // a conflict names the divergences; nothing was applied either way.
            undoFailures[id] = Self.undoFailure(for: error)
        } catch {
            logger.error("Undo failed for \(id, privacy: .public): \(String(describing: error))")
            // The typed failure surfaces inline on the card — a conflict
            // names the divergences; nothing was applied either way.
            undoFailures[id] = Self.undoFailure(for: error)
        }
        await refresh()
    }

    /// Whether an executed proposal still offers Undo — pure so the
    /// affordance rules are directly testable:
    /// - only executed rows offer it (staged rows decide; terminal rows are
    ///   history);
    /// - unrevertable operations never offer it — `RevertPlanBuilder` (the
    ///   authority) builds no revert for scene execution, identify, unblock,
    ///   or accessory removal, so the store would refuse with
    ///   `notRevertable`;
    /// - an EXECUTED revert child means the row is already undone and there
    ///   is no undo of an undo. A failed revert child does not count: the
    ///   store keeps the original's revert plan when its revert fails, so
    ///   Undo still applies.
    static func undoAvailable(for proposal: NilesProposal, proposals: [NilesProposal]) -> Bool {
        guard proposal.state == .executed else { return false }
        guard !unrevertableTools.contains(proposal.tool) else { return false }
        return !proposals.contains { child in
            child.revertsProposalId == proposal.id && child.state == .executed
        }
    }

    /// The staged verbs whose operations have no meaningful inverse. Mirrors
    /// `RevertPlanBuilder`'s unrevertable operation set (the only source of
    /// truth for revertability); if a new unrevertable operation lands in the
    /// store, add its tool here — until then the tap surfaces the store's
    /// typed `notRevertable` and the row stops offering Undo.
    private static let unrevertableTools: Set<String> = [
        "execute_scene", "identify_accessory", "unblock_accessory", "remove_accessory",
    ]

    /// Per-row Undo affordance state: the availability rules above, overlaid
    /// with this session's tap bookkeeping (in flight, divergences, refusals).
    var undoStates: [String: UndoState] {
        var states: [String: UndoState] = [:]
        for proposal in proposals {
            guard Self.undoAvailable(for: proposal, proposals: proposals) else { continue }
            if undosInFlight.contains(proposal.id) {
                states[proposal.id] = .inFlight
            } else if let divergences = undoConflicts[proposal.id] {
                states[proposal.id] = .conflict(divergences)
            } else if notRevertableIds.contains(proposal.id) {
                states[proposal.id] = .notRevertable
            } else {
                states[proposal.id] = .idle
            }
        }
        return states
    }

    /// The card's inline failure from an Undo tap, mapped from the typed
    /// store error. Pure, so tests can pin the wording per error kind.
    static func undoFailure(for error: Error) -> ActivityUndoFailure {
        guard let storeError = error as? ProposalStoreError else {
            return ActivityUndoFailure(message: "Undo failed — nothing was changed.", divergences: [])
        }
        switch storeError {
        case .undoConflict(_, let divergences):
            return ActivityUndoFailure(
                message: "Undo blocked — the home has changed since this was applied. Nothing was changed.",
                divergences: divergences
            )
        case .notRevertable:
            return ActivityUndoFailure(
                message: "Undo is no longer available for this change — nothing was changed.",
                divergences: []
            )
        case .homeReadFailed:
            return ActivityUndoFailure(
                message: "Undo failed — the home could not be read. Nothing was changed.",
                divergences: []
            )
        default:
            return ActivityUndoFailure(
                message: "Undo failed — nothing was changed. (\(storeError))",
                divergences: []
            )
        }
    }

    func clearUndoFailure(_ id: String) {
        undoFailures[id] = nil
    }

    /// Approves and executes every staged proposal immediately —
    /// destructive included. Undo afterwards is per-item, each with its
    /// own conflict check.
    func approveAll() {
        guard let store = coordinator.proposalStore else {
            logger.error("Cannot approve all: no proposal store")
            return
        }
        let stagedIds = beginApproveAllBatch()
        guard !stagedIds.isEmpty else { return }
        Task { await approveAllBatch(on: store, clearing: stagedIds) }
    }

    /// Awaitable batch path — what the tap task spawns; tests await it
    /// directly.
    func approveAllAndWait() async {
        guard let store = coordinator.proposalStore else {
            logger.error("Cannot approve all: no proposal store")
            return
        }
        let stagedIds = beginApproveAllBatch()
        guard !stagedIds.isEmpty else { return }
        await approveAllBatch(on: store, clearing: stagedIds)
    }

    /// Optimistic batch feedback, applied synchronously before the pipeline
    /// task is even spawned — same contract as the single tap: every staged
    /// row shows its in-progress chip on the next frame, one success haptic
    /// fires for the whole batch, and the button cannot re-enter while the
    /// batch runs. Returns the staged ids whose chips must settle.
    @discardableResult
    private func beginApproveAllBatch() -> [String] {
        let stagedIds = proposals.filter(\.isPending).map(\.id)
        guard !stagedIds.isEmpty else { return stagedIds }
        for id in stagedIds {
            decisionsInFlight[id] = .approving
        }
        isApprovingAll = true
        let haptic = UINotificationFeedbackGenerator()
        haptic.prepare()
        haptic.notificationOccurred(.success)
        return stagedIds
    }

    private func approveAllBatch(on store: ProposalStore, clearing stagedIds: [String]) async {
        defer { isApprovingAll = false }
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
        // Settled: the refreshed states are authoritative.
        for id in stagedIds {
            decisionsInFlight[id] = nil
        }
    }

    // MARK: - PairingViewModel

    /// The "New code" tap: discards the live code and mints a fresh one.
    func mintNewCode() {
        Task { await mintNewCodeAndWait() }
    }

    /// Awaitable mint path — what the tap task spawns; tests await it directly.
    /// Mints unconditionally: the tap discards a still-live code, not just a
    /// spent one.
    func mintNewCodeAndWait() async {
        do {
            _ = try await coordinator.pairingCodes.mintCode()
        } catch {
            logger.error("Pairing code mint failed: \(String(describing: error))")
        }
        await refreshPairingState(sessions: await coordinator.sessionInfos())
    }

    /// Revocation: delete the credential, then close any live session the
    /// agent's token created. A failed deletion keeps the session — no half
    /// revocation where the credential outlives the connection it guards.
    func revokeAgent(_ id: UUID) async {
        do {
            try tokenStore.revoke(id: id)
            await coordinator.closeSessions(tokenId: id)
        } catch {
            logger.error("Revoke failed for \(id.uuidString, privacy: .public): \(String(describing: error))")
        }
        await refreshPairingState(sessions: await coordinator.sessionInfos())
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

    // MARK: - ChatViewModel

    /// True when the runner is available and no run is in flight — the
    /// composer's enabled state.
    var canSend: Bool {
        agentRunner != nil && !isChatRunInFlight
    }

    /// One message, one `run(_:)` — identical to Siri, except chat composes
    /// a bounded window of completed transcript rows into the request
    /// (ChatContext). The user row lands optimistically; the agent row runs
    /// until the summary resolves (and staged ids ride the result verbatim)
    /// or the session throws, which renders a failed turn and re-enables
    /// the composer. Concurrent sends are ignored: `canSend` is false from
    /// before the first await.
    func send(_ text: String) async {
        guard canSend, let runner = agentRunner else { return }
        // In-flight and failed rows say nothing about the conversation's
        // state, and staged-proposal ids live in the tools, not the
        // transcript — only completed, non-empty rows compose.
        let request = ChatContext.compose(
            current: text,
            history: entries
                .filter { $0.state == .done && !$0.text.isEmpty }
                .map { ($0.role, $0.text) }
        ) ?? text
        // Entry-point trace for in-app chat: the shared run trace continues
        // in AgentService (and the dispatcher) once the run starts. The
        // composed request is what the agent receives — log that.
        AgentRunTrace.logger.info(
            "Ask Niles run start: entry=in-app chat request: \(AgentRunTrace.truncated(request, to: 500), privacy: .public)"
        )
        await AgentRunTraceStore.shared.recordRunStart(entryPoint: "In-App Chat", request: request)
        entries.append(ChatEntry(id: UUID(), role: .user, text: text))
        let pending = ChatEntry(id: UUID(), role: .agent, text: "", state: .running)
        entries.append(pending)
        isChatRunInFlight = true
        defer { isChatRunInFlight = false }
        do {
            let result = try await runner.run(request)
            ChatTranscript.resolve(pending.id, in: &entries, result: result)
        } catch {
            ChatTranscript.fail(pending.id, in: &entries, with: error)
        }
    }

    // MARK: - Simulator QA fixtures

    /// Screenshots and device QA: with a `-UISeedQueue <fixture>` launch
    /// argument, stages real proposals through the real pipeline (the same
    /// registry the transport serves) so the Queue renders live states
    /// without an MCP client — and, for the conflict fixture, diverges the
    /// fake home and performs the Undo tap so the row shows the typed
    /// divergence error. No-op without the argument.
    func seedQueueFixtureIfRequested() async {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-UISeedQueue"), index + 1 < args.count else { return }
        guard let store = coordinator.proposalStore else {
            logger.error("Seed fixture requested but no proposal store is running")
            return
        }
        // The app target does not link MCP, so fixtures stage hand-built
        // Plans directly. Operations stay real — approve/undo exercise the
        // same execution and revert-derivation paths as agent-staged writes.
        func room(_ id: String, _ name: String?) -> ProposalObjectRef {
            ProposalObjectRef(kind: .room, id: id, name: name)
        }
        func stage(_ plan: Plan) async -> String? {
            _ = await store.stage(plan: plan)
            await refresh()
            return pendingProposals.first { $0.tool == plan.tool }?.id
        }
        func createRoomPlan() -> Plan {
            Plan(
                tool: "create_room",
                title: "Create room Studio",
                summary: "Adds the Studio room to the home.",
                isDestructive: false,
                operations: [.addRoom(homeId: "home-1", name: "Studio")],
                entries: [.init(object: room("", "Studio"), op: .create, before: nil, after: "Studio")],
                card: [.init(.add, "Add room Studio")]
            )
        }

        switch args[index + 1] {
        case "pending":
            _ = await stage(createRoomPlan())
            _ = await stage(Plan(
                tool: "rename_room",
                title: "Rename room to Cookery",
                summary: "Renames room-2 to Cookery.",
                isDestructive: false,
                operations: [.renameRoom(homeId: "home-1", roomId: "room-2", to: "Cookery")],
                entries: [.init(object: room("room-2", "Cookery"), op: .rename, before: nil, after: "Cookery")],
                card: [.init(.plain, "Rename room to Cookery")]
            ))

        case "destructive":
            _ = await stage(createRoomPlan())
            _ = await stage(Plan(
                tool: "delete_room",
                title: "Delete room",
                summary: "Removes room-3 and its accessory assignments.",
                isDestructive: true,
                operations: [.removeRoom(homeId: "home-1", roomId: "room-3")],
                entries: [.init(object: room("room-3", nil), op: .delete, before: nil, after: nil)],
                card: [.init(.remove, "Delete room-3"), .init(.note, "Accessories in this room become unassigned.")]
            ))

        case "undo":
            guard let id = await stage(createRoomPlan()) else { return }
            await approveAndWait(id)

        case "conflict":
            guard let id = await stage(createRoomPlan()) else { return }
            await approveAndWait(id)
            // Diverge the home out-of-band — the revert expects the created
            // room to still exist, so removing it directly is exactly the
            // "the world moved" case the conflict check exists for.
            do {
                let graph = try await store.homeKit.snapshot()
                let home = graph.homes.first
                guard let room = home?.rooms.first(where: { $0.name == "Studio" }) else { return }
                _ = try await store.homeKit.perform(.removeRoom(homeId: home?.id ?? "", roomId: room.id))
                // The Undo tap, performed exactly as the row's button does it.
                await undoAndWait(id)
            } catch {
                logger.error("Conflict fixture diverge failed: \(String(describing: error))")
            }

        default:
            logger.error("Unknown -UISeedQueue fixture: \(args[index + 1], privacy: .public)")
        }
        await refresh()
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
        await refreshPairingState(sessions: sessions)

        if let runner = agentRunner {
            agentUsage = await runner.usage
        }

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

    // MARK: - Pairing state

    /// The pairing card's state: a live code (auto-minted when refresh finds
    /// none — expiry, a successful exchange, and an attempt-cap burn all land
    /// here, so foreground-after-expiry shows a fresh one) and the paired
    /// credentials with what the live sessions say about them.
    private func refreshPairingState(sessions: [MCPGateway.SessionInfo]) async {
        await mintPairingCode()
        if let code = await coordinator.pairingCodes.activeCode() {
            pairingCode = code.code
            codeExpiresAt = code.expiresAt
        }

        do {
            pairedAgents = Self.pairedAgentRows(
                agents: try tokenStore.listAgents(),
                sessions: sessions,
                now: Date()
            )
        } catch {
            // The Keychain read failing keeps the previous list on screen —
            // logged, never silently dropped.
            logger.error("Paired-agent read failed, keeping previous list: \(String(describing: error))")
        }
    }

    /// Mints a code when none is live. A mint failure is logged, not thrown —
    /// the countdown then shows the previous expiry, never a fabricated code.
    private func mintPairingCode() async {
        guard await coordinator.pairingCodes.activeCode() == nil else { return }
        do {
            _ = try await coordinator.pairingCodes.mintCode()
        } catch {
            logger.error("Pairing code mint failed: \(String(describing: error))")
        }
    }

    /// The paired-agents rows from stored credentials and live sessions —
    /// pure, so the list's rendering rules are directly testable. Unnamed
    /// agents render as "Agent"; last seen comes from the newest session the
    /// agent's token created.
    static func pairedAgentRows(
        agents: [PairedAgent],
        sessions: [MCPGateway.SessionInfo],
        now: Date
    ) -> [PairedAgentRow] {
        agents.map { agent in
            let agentSessions = sessions
                .filter { $0.tokenId == agent.id }
                .sorted { $0.startedAt > $1.startedAt }
            let lastSeen = agentSessions.map(\.lastAccessedAt).max()
            let pairedDate = agent.pairedAt.formatted(date: .abbreviated, time: .omitted)
            let seen = lastSeen.map { "last seen \(RelativeTime.label(for: $0, now: now))" } ?? "never connected"
            return PairedAgentRow(
                id: agent.id,
                name: agent.name ?? "Agent",
                detail: "paired \(pairedDate) · \(seen)",
                pairedAt: agent.pairedAt,
                sessions: agentSessions.map { session in
                    AgentSessionRow(
                        id: session.id,
                        clientName: session.clientName ?? "MCP client",
                        startedAt: session.startedAt,
                        lastAccessedAt: session.lastAccessedAt
                    )
                }
            )
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
