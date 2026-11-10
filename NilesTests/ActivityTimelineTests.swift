import Foundation
import MCP
import NilesCore
import Testing
@testable import Niles

private struct ActivityTestTimeout: Error {}

/// Waits (on the main actor) until `condition` holds or the timeout expires.
@MainActor
private func waitUntil(
    timeout: TimeInterval = 5,
    _ condition: () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else { throw ActivityTestTimeout() }
        try await Task.sleep(for: .milliseconds(50))
    }
}

/// The Activity timeline's pure view-model logic: ordering, recency
/// grouping, verdict chips, undone rendering with the revert's linked
/// evidence, and the undo-availability gates. Plus the live store's typed
/// undo-conflict surfacing.
@MainActor
struct ActivityTimelineTests {

    // MARK: - Fixtures

    /// Anchor at local noon: every bucket fixture ("Today", "Yesterday", …)
    /// offsets from this clock, so a run near midnight can't push an event
    /// across a calendar boundary. CI hit exactly that at 01:25 UTC —
    /// now−26h landed the day before yesterday and the "Yesterday" bucket
    /// vanished from timelineGroupsByRecency.
    private let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)

    private func event(
        _ kind: ActivityEvent.Kind,
        minutesAgo: TimeInterval,
        proposalId: String,
        title: String = "A proposal",
        agentName: String? = "Claude Code",
        decision: String? = nil,
        detail: String? = nil,
        evidence: [ProposalEvidence] = []
    ) -> ActivityEvent {
        ActivityEvent(
            at: now.addingTimeInterval(-minutesAgo * 60),
            kind: kind,
            proposalId: proposalId,
            proposalTitle: title,
            agentName: agentName,
            decision: decision,
            detail: detail,
            evidence: evidence
        )
    }

    private func proposal(
        id: String,
        tool: String = "create_room",
        state: ProposalState = .executed,
        reverts: String? = nil,
        title: String = "A proposal",
        minutesAgo: TimeInterval = 30
    ) -> NilesProposal {
        NilesProposal(
            id: id,
            tool: tool,
            title: title,
            agentName: "Claude Code",
            createdAt: now.addingTimeInterval(-minutesAgo * 60),
            isDestructive: false,
            evidence: [],
            diff: [],
            state: state,
            revertsProposalId: reverts
        )
    }

    private func confirmedEvidence(_ claim: String) -> [ProposalEvidence] {
        [ProposalEvidence(claim: claim, observed: "confirmed", confirmed: true)]
    }

    // MARK: - Ordering and grouping

    /// The log is append-ordered (oldest first); the timeline renders newest
    /// first regardless of input order.
    @Test
    func timelineRendersNewestFirst() {
        let events = [
            event(.staged, minutesAgo: 30, proposalId: "prop_1"),
            event(.decided, minutesAgo: 20, proposalId: "prop_1", decision: "approved"),
            event(.executed, minutesAgo: 10, proposalId: "prop_1"),
        ]
        let rows = ActivityTimeline.rows(events: events, proposals: [])
        #expect(rows.map { $0.event.kind } == [.executed, .decided, .staged])
    }

    /// Events group into recency buckets, newest bucket first. Each fixture
    /// date is anchored to a midnight boundary so the expected buckets hold
    /// no matter what time of day the suite runs.
    @Test
    func timelineGroupsByRecency() {
        // Anchor fixture events to calendar days, not fixed offsets from
        // now: a fixed "26h ago" falls outside Yesterday whenever the test
        // runs within two hours of local midnight (CI runs in UTC).
        let calendar = Calendar.current
        let now = self.now
        let startOfToday = calendar.startOfDay(for: now)
        let today = max(startOfToday, now.addingTimeInterval(-30 * 60))
        let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)!
            .addingTimeInterval(12 * 3600)
        let thisWeek = calendar.date(byAdding: .day, value: -3, to: startOfToday)!
            .addingTimeInterval(12 * 3600)
        let earlier = calendar.date(byAdding: .day, value: -20, to: startOfToday)!
            .addingTimeInterval(12 * 3600)
        let minutesAgo = { (date: Date) in now.timeIntervalSince(date) / 60 }
        let events = [
            event(.staged, minutesAgo: minutesAgo(today), proposalId: "prop_today"),
            event(.expired, minutesAgo: minutesAgo(yesterday), proposalId: "prop_yesterday"),
            event(.executed, minutesAgo: minutesAgo(thisWeek), proposalId: "prop_this_week"),
            event(.executed, minutesAgo: minutesAgo(earlier), proposalId: "prop_earlier"),
        ]
        let sections = ActivityTimeline.sections(
            rows: ActivityTimeline.rows(events: events, proposals: []),
            now: now
        )
        #expect(sections.map { $0.title } == ["Today", "Yesterday", "This Week", "Earlier"])
        #expect(sections[0].rows.count == 1)
        #expect(sections[0].rows[0].event.proposalId == "prop_today")
    }

    // MARK: - Verdict chips

    /// A decided event renders its decision; an executed event that recorded
    /// a failure renders FAILED even after the proposal leaves memory.
    @Test
    func verdictsMapFromEventContent() {
        let events = [
            event(.staged, minutesAgo: 40, proposalId: "prop_a"),
            event(.decided, minutesAgo: 30, proposalId: "prop_a", decision: "approved"),
            event(.decided, minutesAgo: 20, proposalId: "prop_b", decision: "denied"),
            event(.expired, minutesAgo: 15, proposalId: "prop_c"),
            event(
                .executed, minutesAgo: 10, proposalId: "prop_d",
                detail: "Failed — The operation couldn't be completed"
            ),
        ]
        let verdicts = ActivityTimeline.rows(events: events, proposals: []).map { $0.verdict }
        #expect(verdicts == [.failed, .expired, .denied, .approved, .staged])
    }

    /// A failed live proposal renders FAILED even without the outcome line.
    @Test
    func failedProposalRendersFailed() {
        let events = [event(.executed, minutesAgo: 10, proposalId: "prop_x")]
        let rows = ActivityTimeline.rows(events: events, proposals: [
            proposal(id: "prop_x", state: .failed)
        ])
        #expect(rows[0].verdict == .failed)
    }

    // MARK: - Tool line

    /// The tool line names the tool while the proposal is in memory, and
    /// falls back to the proposal id for history that outlived it.
    @Test
    func toolLinePrefersTheLiveProposal() {
        let events = [event(.executed, minutesAgo: 10, proposalId: "prop_x")]
        let live = ActivityTimeline.rows(events: events, proposals: [proposal(id: "prop_x", tool: "rename_room")])
        #expect(live[0].toolLine == "rename_room · prop_x")

        let relaunched = ActivityTimeline.rows(events: events, proposals: [])
        #expect(relaunched[0].toolLine == "prop_x")
    }

    // MARK: - Undone rendering

    /// An undone entry stays marked UNDONE and carries the revert's own
    /// read-back evidence, found through the live revert's link to the
    /// original proposal.
    @Test
    func undoneRowsStayMarkedAndCarryRevertEvidence() throws {
        let events = [
            event(.staged, minutesAgo: 60, proposalId: "prop_orig"),
            event(.decided, minutesAgo: 55, proposalId: "prop_orig", decision: "approved"),
            event(.executed, minutesAgo: 50, proposalId: "prop_orig", detail: "1 of 1 checks confirmed"),
            event(
                .executed, minutesAgo: 20, proposalId: "prop_revert",
                title: "Undo — A proposal", detail: "1 of 1 checks confirmed — revert of “A proposal”",
                evidence: confirmedEvidence("No room remains")
            ),
            event(.undone, minutesAgo: 21, proposalId: "prop_orig", detail: "Reverted — Undo — A proposal"),
        ]
        let proposals = [
            proposal(id: "prop_orig", state: .executed),
            proposal(id: "prop_revert", reverts: "prop_orig", title: "Undo — A proposal", minutesAgo: 20),
        ]
        let rows = ActivityTimeline.rows(events: events, proposals: proposals)

        let undone = try #require(rows.first { $0.event.kind == .undone })
        #expect(undone.verdict == .undone)
        #expect(undone.undoAvailable == false)
        #expect(undone.revertEvidence == confirmedEvidence("No room remains"))
        #expect(undone.revertTitle == "Undo — A proposal")
    }

    /// After a relaunch the revert link is gone (proposals are in-memory);
    /// the UNDONE marker survives with an empty evidence payload.
    @Test
    func undoneRowsRenderWithoutALiveRevertLink() throws {
        let events = [
            event(.executed, minutesAgo: 50, proposalId: "prop_orig"),
            event(.undone, minutesAgo: 21, proposalId: "prop_orig"),
        ]
        let rows = ActivityTimeline.rows(events: events, proposals: [])
        let undone = try #require(rows.first { $0.event.kind == .undone })
        #expect(undone.verdict == .undone)
        #expect(undone.revertEvidence.isEmpty)
        #expect(undone.revertTitle == nil)
    }

    // MARK: - Undo availability

    @Test
    func undoAvailabilityGates() {
        func availability(
            _ event: ActivityEvent,
            events: [ActivityEvent],
            proposals: [NilesProposal]
        ) -> Bool {
            ActivityTimeline.undoAvailability(event: event, events: events, proposals: proposals)
        }

        // A clean, recent execution: Undo.
        let executed = event(.executed, minutesAgo: 10, proposalId: "prop_ok")
        #expect(availability(executed, events: [executed], proposals: [proposal(id: "prop_ok")]))

        // Staged, decided, and expired events never offer Undo.
        for other in [
            event(.staged, minutesAgo: 10, proposalId: "prop_ok"),
            event(.decided, minutesAgo: 10, proposalId: "prop_ok", decision: "approved"),
            event(.expired, minutesAgo: 10, proposalId: "prop_ok"),
        ] {
            #expect(!availability(other, events: [other], proposals: [proposal(id: "prop_ok")]))
        }

        // An undone event in the log: already undone, no undo of an undo.
        let undone = event(.undone, minutesAgo: 5, proposalId: "prop_ok")
        #expect(!availability(executed, events: [executed, undone], proposals: [proposal(id: "prop_ok")]))

        // A live revert proposal still links the original: undone.
        #expect(!availability(executed, events: [executed], proposals: [
            proposal(id: "prop_ok"),
            proposal(id: "prop_revert", reverts: "prop_ok", minutesAgo: 5),
        ]))

        // The executed proposal left memory (relaunch): the revert plan went
        // with it — history offers nothing.
        #expect(!availability(executed, events: [executed], proposals: []))

        // The proposal moved on (re-staged or failed since): no Undo.
        #expect(!availability(executed, events: [executed], proposals: [
            proposal(id: "prop_ok", state: .staged)
        ]))

        // Scene execution has no meaningful inverse: never Undo.
        let scene = event(.executed, minutesAgo: 10, proposalId: "prop_scene")
        #expect(!availability(scene, events: [scene], proposals: [
            proposal(id: "prop_scene", tool: "execute_scene")
        ]))
    }

    // MARK: - One row per proposal

    /// All of a proposal's events collapse into one group; distinct
    /// proposals stay distinct rows, newest proposal first.
    @Test
    func groupsCollapsesToProposalRows() {
        let events = [
            event(.staged, minutesAgo: 30, proposalId: "prop_1"),
            event(.decided, minutesAgo: 20, proposalId: "prop_1", decision: "approved"),
            event(.executed, minutesAgo: 10, proposalId: "prop_1"),
            event(.staged, minutesAgo: 5, proposalId: "prop_2"),
        ]
        let groups = ActivityTimeline.groups(events: events, proposals: [])
        #expect(groups.map(\.proposalId) == ["prop_2", "prop_1"])
        #expect(groups[1].title == "A proposal")
        // The executed event is the most recent of prop_1.
        #expect(groups[1].latestAt == events[2].at)
        // The lifecycle timeline is newest first inside the group.
        #expect(groups[1].events.map { $0.event.kind } == [.executed, .decided, .staged])
    }

    /// The group's state is the furthest lifecycle state reached: undone
    /// dominates, then failed, executed, decided, expired, staged.
    @Test
    func groupStateIsTheFurthestStateReached() {
        func state(_ events: [ActivityEvent]) -> ActivityTimeline.Verdict {
            ActivityTimeline.groups(events: events, proposals: []).first!.state
        }
        #expect(state([event(.staged, minutesAgo: 10, proposalId: "p")]) == .staged)
        #expect(state([
            event(.staged, minutesAgo: 10, proposalId: "p"),
            event(.decided, minutesAgo: 5, proposalId: "p", decision: "approved"),
        ]) == .approved)
        #expect(state([
            event(.staged, minutesAgo: 10, proposalId: "p"),
            event(.executed, minutesAgo: 5, proposalId: "p"),
        ]) == .executed)
        #expect(state([
            event(.executed, minutesAgo: 10, proposalId: "p"),
            event(.undone, minutesAgo: 5, proposalId: "p"),
        ]) == .undone)
        #expect(state([
            event(.executed, minutesAgo: 10, proposalId: "p", detail: "Failed — boom"),
        ]) == .failed)
    }

    /// The group carries the undo gates of its most recent execution —
    /// an undone proposal never offers Undo.
    @Test
    func groupUndoAvailabilityFollowsTheExecution() {
        let executed = event(.executed, minutesAgo: 10, proposalId: "prop_ok")
        let undone = event(.undone, minutesAgo: 5, proposalId: "prop_ok")
        let groups = ActivityTimeline.groups(
            events: [executed, undone],
            proposals: [proposal(id: "prop_ok")]
        )
        #expect(groups.first?.state == .undone)
        #expect(groups.first?.undoAvailable == false)
    }

    // MARK: - Plain-language evidence

    /// The raw "1 of 1 checks confirmed" tally is never surfaced: the
    /// summary tells the person what was done, with counts only as context.
    @Test
    func evidenceSummarySpeaksPlainLanguage() {
        #expect(ActivityTimeline.evidenceSummary([]) == nil)
        #expect(
            ActivityTimeline.evidenceSummary(confirmedEvidence("Room exists"))
                == "Re-read the home after execution; state matched expectations (1 check)."
        )
        #expect(
            ActivityTimeline.evidenceSummary([
                confirmedEvidence("Room exists")[0],
                confirmedEvidence("Name matches")[0],
            ]) == "Re-read the home after execution; state matched expectations (2 checks)."
        )
        #expect(
            ActivityTimeline.evidenceSummary([
                confirmedEvidence("Room exists")[0],
                ProposalEvidence(claim: "Name matches", observed: "It does not", confirmed: false),
            ]) == "Re-read the home after execution; 1 check of 2 checks matched expectations."
        )
        #expect(
            ActivityTimeline.evidenceSummary([
                ProposalEvidence(claim: "Room exists", observed: "It does not", confirmed: false),
            ]) == "Re-read the home after execution; the home did not match expectations."
        )
    }

    // MARK: - Live undo-conflict surfacing

    /// A conflicted revert surfaces the typed undoConflict inline: the
    /// failure block carries the divergences, nothing was applied, and the
    /// card keeps its executed state.
    @Test
    func conflictedUndoSurfacesTheTypedErrorInline() async throws {
        let fake = FakeHomeKitService(graph: .demoFixture)
        let coordinator = ServerCoordinator(tokenStore: StaticTokenStore(token: "test-token"), homeKitService: fake)
        let store = LiveNilesStore(
            coordinator: coordinator,
            notifier: .disabled,
            activityLog: ActivityLog(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("niles-activity-\(UUID().uuidString)", isDirectory: true))
        )
        await store.refresh()
        let registry = WriteToolRegistry(store: try #require(coordinator.proposalStore))

        // Create a room, approve it — the execution whose undo will conflict.
        _ = try await registry.call(
            name: "create_room",
            arguments: ["homeId": .string("home-1"), "name": .string("Studio")]
        )
        await store.refresh()
        let created = try #require(store.pendingProposals.first { $0.tool == "create_room" })
        await store.approveAndWait(created.id)
        try await waitUntil { store.proposals.first { $0.id == created.id }?.state == .executed }

        // Then delete the room out from under the undo — the home no longer
        // matches what the create produced.
        let home = try await fake.snapshot()
        let roomId = try #require(home.homes[0].rooms.first { $0.name == "Studio" }?.id)
        _ = try await registry.call(
            name: "delete_room",
            arguments: ["roomId": .string(roomId)]
        )
        await store.refresh()
        let deletion = try #require(store.pendingProposals.first { $0.tool == "delete_room" })
        await store.approveAndWait(deletion.id)
        try await waitUntil { store.proposals.first { $0.id == deletion.id }?.state == .executed }

        // The Undo tap: conflict, surfaced inline, nothing applied.
        await store.undoAndWait(created.id)
        let failure = try #require(store.undoFailures[created.id])
        #expect(failure.divergences.isEmpty == false)
        #expect(failure.message.contains("blocked"))
        #expect(store.proposals.first { $0.id == created.id }?.state == .executed)

        // The failure clears on the next successful path: dismissing it.
        store.clearUndoFailure(created.id)
        #expect(store.undoFailures[created.id] == nil)
    }

    /// The typed failure mapping, pinned per error kind.
    @Test
    func undoFailureMappingPinsTheWording() {
        let conflict = LiveNilesStore.undoFailure(for: ProposalStoreError.undoConflict(
            id: "prop_x",
            divergences: [ProposalEvidence(claim: "Room exists", observed: "It does not", confirmed: false)]
        ))
        #expect(conflict.message.contains("blocked"))
        #expect(conflict.divergences.count == 1)

        let notRevertable = LiveNilesStore.undoFailure(for: ProposalStoreError.notRevertable(id: "prop_x"))
        #expect(notRevertable.divergences.isEmpty)
        #expect(notRevertable.message.contains("no longer available"))
    }
}
