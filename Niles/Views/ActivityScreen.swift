import SwiftUI
import NilesCore

/// The Activity timeline: one row per proposal, sectioned per calendar day.
/// The persistent event log is grouped by proposal id at the view layer, so
/// a proposal's staged / approved / executed history collapses into a single
/// card showing its human-readable summary, current lifecycle state, and
/// most recent timestamp. Tapping opens a detail view with the full
/// lifecycle timeline and structured read-back evidence. Recent executed
/// rows offer Undo as a swipe action; undone entries stay marked Undone.
/// A proposal appears here once it has been decided — pending (staged)
/// items stay in the Queue alone, except an in-flight swipe decision,
/// which renders here as a processing row (Denying…/Executing…) while
/// the pipeline runs.
struct ActivityScreen: View {
    var model: any ActivityViewModel

    /// Inline-title pin for this pane's bar — set in the wide layout by
    /// widePane(); false (automatic) in the narrow layout. See ContentView.
    @Environment(\.widePaneInlineTitle) private var widePaneInlineTitle

    var body: some View {
        NavigationStack {
            List {
                ActivitySections(model: model)
            }
            .navigationTitle("Activity")
            // Shared bar modifier: in the wide layout the leading pane never registers the top
            // scroll-edge effect — the system status pillar sits over the
            // trailing pane's x-range — so its bar falls back to the legacy
            // expanded large-title geometry (110 pt, title below an empty
            // 58 pt inline zone). Each pane applies the shared inline pin
            // from widePane()'s environment — pinned in the wide layout,
            // automatic (untouched) in the narrow layout.
            .navigationBarTitleDisplayMode(widePaneInlineTitle ? .inline : .automatic)
            // No explicit .contentMargins on the List: an explicit
            // horizontal scroll-content margin REPLACES the
            // safe-area-derived one, and on the Duo that is the 84 pt
            // sensor-housing/status-pillar clearance (device-measured —
            // with the margin set, rows rendered under the
            // pillar). The default grouped-list margins already give the
            // 20 pt gutters, and keeping margins off the stack wrapper
            // avoids the bar scroll-edge interference seen in the
            // wide layout.
            // Safe-area diagnostics: -UISafeAreaProbe overlays the
            // List's measured insets and boundary lines.
            .overlay(alignment: .bottomLeading) {
                if SafeAreaProbe.active {
                    SafeAreaOverlay(label: "activity.list", badgeAlignment: .topLeading)
                }
            }
        }
    }
}

/// Activity's timeline as list sections — the content BOTH the wide
/// layout's Activity pane and the compact single page (HomeScreen's list,
/// which appends these below its Server section) render. Self-contained:
/// owns the detail-sheet state (a row tap opens the sheet) and the
/// `-UIActivityOpenDetail` fixture hook, so either host gets identical
/// behavior with no extra wiring. The body is a Group of Sections, which
/// flattens into the host List as one Section per calendar day.
struct ActivitySections: View {
    var model: any ActivityViewModel

    @State private var openDetail: ActivityTimeline.Group?
    /// Screenshot hook: `-UIActivityOpenDetail` presents the newest proposal's
    /// detail sheet on launch, so per-proposal captures need no UI automation.
    @State private var autoOpenedDetail = false

    var body: some View {
        Group {
            let groups = Self.decidedGroups(
                events: model.activityEvents, proposals: model.proposals,
                decisionsInFlight: model.decisionsInFlight
            )
            if groups.isEmpty {
                // A bare Group child (no Section): renders in the host List
                // exactly as ActivityScreen's empty state always has.
                ContentUnavailableView(
                    "No activity yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Proposals appear here once you approve or deny them — pending items wait in the Queue.")
                )
            } else {
                ForEach(ActivityDaySections(groups: groups)) { section in
                    Section(section.title) {
                        ForEach(section.groups) { group in
                            groupRow(group)
                        }
                    }
                }
            }
        }
        .sheet(item: $openDetail) { group in
            // Rebuild the group from the model so the sheet reflects undo
            // taps and refreshed evidence, like the approvals sheet does.
            if let fresh = Self.decidedGroups(
                events: model.activityEvents, proposals: model.proposals,
                decisionsInFlight: model.decisionsInFlight
            ).first(where: { $0.proposalId == group.proposalId }) {
                ActivityDetailView(
                    group: fresh,
                    failure: model.undoFailures[fresh.proposalId],
                    undoInFlight: model.undoStates[fresh.proposalId] == .inFlight,
                    onUndo: { model.undo(fresh.proposalId) },
                    onDismissFailure: { model.clearUndoFailure(fresh.proposalId) }
                )
            }
        }
        .task {
            if !autoOpenedDetail,
               LaunchArguments.uiActivityOpenDetail,
               let newest = Self.decidedGroups(
                   events: model.activityEvents, proposals: model.proposals,
                   decisionsInFlight: model.decisionsInFlight
               ).first {
                openDetail = newest
                autoOpenedDetail = true
            }
        }
    }

    /// Pending (staged) proposals never render here — Activity starts at
    /// the decision — with one exception: a proposal whose swipe decision
    /// is still in flight renders as a processing row (decided-in-progress,
    /// the 2026-11-12 rule). A proposal no longer in memory (after a
    /// relaunch) is settled history and always shows.
    private static func decidedGroups(
        events: [ActivityEvent],
        proposals: [NilesProposal],
        decisionsInFlight: [String: ProposalDecision]
    ) -> [ActivityTimeline.Group] {
        ActivityTimeline.groups(
            events: events, proposals: proposals, decisionsInFlight: decisionsInFlight
        ).filter { group in
            if decisionsInFlight[group.proposalId] != nil { return true }
            guard let proposal = proposals.first(where: { $0.id == group.proposalId }) else { return true }
            return proposal.state != .staged
        }
    }

    private func groupRow(_ group: ActivityTimeline.Group) -> some View {
        Button {
            openDetail = group
        } label: {
            HStack(alignment: .firstTextBaseline) {
                // Destructive rows always carry the red trash can (Matthew,
                // 2026-11-13) — keyed off the proposal's destructive
                // classification, never a name match.
                Image(systemName: group.isDestructive ? "trash" : group.state.symbol)
                    .foregroundStyle(group.isDestructive ? Color.red : group.state.tint)
                    // Nudge the symbol off the first-text-baseline: SF Symbols
                    // ride high beside a text line — drop it ~2pt so it sits
                    // level with the headline (2026-11-14).
                    .baselineOffset(-2)
                VStack(alignment: .leading, spacing: 4) {
                    // The human-readable summary is the headline; the tool
                    // name and prop_ id live in the detail sheet only. Titles
                    // with a “…” quoted entity split into action + entity
                    // (`Rename` / `Kitchen`) — ProposalTitleParts — so long
                    // names wrap on their own line; one-line otherwise.
                    if let parts = ProposalTitleParts.split(group.title) {
                        Text(parts.action)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(parts.entity)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(group.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    // A processing row spins beside its timestamp — the
                    // pipeline is still running. The label names the phase
                    // (Denying…/Executing…) so the state is readable, not
                    // just color and motion.
                    if group.state == .denying || group.state == .executing {
                        HStack(spacing: 6) {
                            ProgressView()
                            Text(group.state.label)
                                .font(.footnote)
                                .foregroundStyle(group.state.tint)
                        }
                    }
                    // An undo in flight gets the same treatment: on a real
                    // home the revert write plus read-back takes seconds, and
                    // a silent row reads as a dead tap (the 2026-11-13 report).
                    if model.undoStates[group.proposalId] == .inFlight {
                        HStack(spacing: 6) {
                            ProgressView()
                            Text("Undoing…")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(RelativeTime.label(for: group.latestAt))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        // Plain keeps the label's .primary/.secondary styles honest: the
        // default button style under the app-wide .tint(.white) renders
        // .primary text white-on-white in light mode (same pairing-row
        // lesson from UI pass 2).
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            if group.undoAvailable {
                Button {
                    model.undo(group.proposalId)
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                // Orange: a reversal, not a deletion — caution without destructive red.
                .tint(.orange) // the app-wide .tint(.white) otherwise overrides system styling
                .disabled(model.undoStates[group.proposalId] == .inFlight)
            }
        }
    }
}

// MARK: - Verdict presentation

extension ActivityTimeline.Verdict {
    /// The SF Symbol standing in for the old verdict chip. Status is never
    /// color alone — every verdict carries its symbol and label too.
    var symbol: String {
        switch self {
        case .staged: "doc.text"
        case .approved: "checkmark.circle"
        case .denied: "xmark.circle"
        case .executed: "checkmark.seal"
        case .failed: "xmark.octagon"
        case .expired: "clock.badge.xmark"
        case .undone: "arrow.uturn.backward.circle"
        case .denying, .executing: "arrow.triangle.2.circlepath"
        }
    }

    /// System status colors by meaning: red reserved for denial and failure,
    /// gray for the terminal-but-neutral expired and undone states, blue
    /// for the in-flight processing states.
    var tint: Color {
        switch self {
        case .staged: .orange
        case .approved, .executed: .green
        case .denied, .failed: .red
        case .expired, .undone: .secondary
        case .denying, .executing: .blue
        }
    }

    var label: String {
        switch self {
        case .staged: "Staged"
        case .approved: "Approved"
        case .denied: "Denied"
        case .executed: "Executed"
        case .failed: "Failed"
        case .expired: "Expired"
        case .undone: "Undone"
        case .denying: "Denying…"
        case .executing: "Executing…"
        }
    }
}

// MARK: - Day sections

/// One calendar day of proposal cards, newest first, keyed on each group's
/// most recent event. The view-layer grouping behind the native list headers
/// — the model's recency buckets (Today / Yesterday / This Week / Earlier)
/// stay untouched in the view-model layer this screen's tests pin.
struct ActivityDaySection: Identifiable {
    let title: String
    let groups: [ActivityTimeline.Group]
    var id: String { title }
}

/// Groups proposal cards by calendar day, newest day first, with friendly
/// headers for today and yesterday and abbreviated dates beyond.
struct ActivityDaySections: RandomAccessCollection {
    let sections: [ActivityDaySection]

    init(
        groups: [ActivityTimeline.Group],
        calendar: Calendar = .current,
        now: Date = Date()
    ) {
        var buckets: [(date: Date, groups: [ActivityTimeline.Group])] = []
        for group in groups {
            let day = calendar.startOfDay(for: group.latestAt)
            if let index = buckets.firstIndex(where: { $0.date == day }) {
                buckets[index].groups.append(group)
            } else {
                buckets.append((day, [group]))
            }
        }
        sections = buckets.map { bucket in
            ActivityDaySection(
                title: Self.title(for: bucket.date, calendar: calendar, now: now),
                groups: bucket.groups
            )
        }
    }

    private static func title(for day: Date, calendar: Calendar, now: Date) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return day.formatted(date: .abbreviated, time: .omitted)
    }

    var startIndex: Int { sections.startIndex }
    var endIndex: Int { sections.endIndex }
    subscript(position: Int) -> ActivityDaySection { sections[position] }
}

// MARK: - Detail sheet

/// The detail sheet behind a tapped proposal card: the full lifecycle
/// timeline (staged, decided, executed — oldest first), the structured
/// read-back evidence in plain language, the undo's own evidence for undone
/// entries, and any blocked-undo conflict. The MCP tool name and proposal id
/// sit in a secondary monospaced plumbing section — kept for debugging and
/// cross-referencing the queue, but never the headline.
struct ActivityDetailView: View {
    let group: ActivityTimeline.Group
    var failure: ActivityUndoFailure?
    var undoInFlight: Bool = false
    var onUndo: () -> Void = {}
    var onDismissFailure: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                // Blocked undo leads the card: at the medium detent everything
                // below the timeline scrolls out of view, and a failure that
                // renders under the fold reads as a dead tap (2026-11-13).
                if let failure {
                    Section("Undo blocked") {
                        Text(failure.message)
                            .font(.callout)
                            .foregroundStyle(.red)
                        ForEach(Array(failure.divergences.enumerated()), id: \.offset) { _, item in
                            Label("\(item.claim) — \(item.observed)", systemImage: "xmark.circle")
                                .foregroundStyle(.red)
                        }
                        Button("Dismiss") {
                            onDismissFailure()
                            dismiss()
                        }
                    }
                }
                Section("Timeline") {
                    ForEach(Array(group.events.reversed().enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .firstTextBaseline) {
                            Image(systemName: entry.verdict.symbol)
                                .foregroundStyle(entry.verdict.tint)
                            Text(entry.verdict.label)
                            Spacer()
                            Text(entry.event.at.formatted(date: .abbreviated, time: .shortened))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let summary = ActivityTimeline.evidenceSummary(group.evidence) {
                    Section("Read-back evidence") {
                        Text(summary)
                            .font(.callout)
                        evidenceRows(group.evidence)
                    }
                }
                if group.state == .undone {
                    // The revert's own read-back, linked to the original: the
                    // undo's evidence lives on the revert, not the undone event.
                    Section("Reverted by \(group.revertTitle ?? "a paired revert")") {
                        if group.revertEvidence.isEmpty {
                            Text("The revert's read-back is available while its proposal is in memory.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            evidenceRows(group.revertEvidence)
                        }
                    }
                }
                Section("Details") {
                    if let agent = group.events.first?.event.agentName {
                        LabeledContent("Agent", value: agent)
                    }
                    LabeledContent("Tool") {
                        Text(group.toolName ?? "—")
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Proposal") {
                        Text(group.proposalId)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                // The old trailing "Undo blocked" section moved above the
                // timeline so a failure is visible at the medium detent.
            }
            .navigationTitle(group.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if group.undoAvailable {
                        Button("Undo", systemImage: "arrow.uturn.backward") {
                            onUndo()
                        }
                        // Orange keeps the undo readable: the app-wide
                        // .tint(.white) rendered this toolbar button white
                        // on white, so the card looked Undo-less (2026-11-13).
                        .tint(.orange)
                        .disabled(undoInFlight)
                    } else {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func evidenceRows(_ evidence: [ProposalEvidence]) -> some View {
        ForEach(Array(evidence.enumerated()), id: \.offset) { _, item in
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: item.notRun
                    ? "minus.circle"
                    : (item.confirmed ? "checkmark.circle" : "xmark.circle"))
                    .foregroundStyle(item.notRun
                        ? Color.secondary
                        : (item.confirmed ? Color.green : Color.red))
                Text("\(item.claim) — \(item.observed)")
            }
        }
    }
}

// MARK: - Previews and the screenshot fixture

/// In-memory fixture behind the Activity previews and the screenshot hook
/// (`-UIActivityFixtures` launches the app on it): one afternoon's log with
/// every verdict, a full staged→approved→executed lifecycle, an undo, and an
/// unrevertable scene execution — one proposal each, so the list reads as
/// one row per proposal.
@MainActor
@Observable
final class FixtureActivityStore: ActivityViewModel {
    let activityEvents: [ActivityEvent]
    let proposals: [NilesProposal]
    /// The fixture store settles synchronously — nothing is in flight.
    let decisionsInFlight: [String: ProposalDecision] = [:]
    var undoFailures: [String: ActivityUndoFailure] = [:]
    var undoStates: [String: UndoState] = [:]

    func undo(_ id: String) {}
    func clearUndoFailure(_ id: String) { undoFailures[id] = nil }

    init(now: Date = Date()) {
        let minute: TimeInterval = 60
        let hour: TimeInterval = 60 * minute
        func evidence(_ claim: String) -> [ProposalEvidence] {
            [ProposalEvidence(claim: claim, observed: "\(claim) — confirmed on the live home", confirmed: true)]
        }

        proposals = [
            NilesProposal(
                id: "prop_fix_staged",
                tool: "set_zone_rooms",
                title: "Move Office into Upstairs",
                agentName: "Claude Code",
                createdAt: now.addingTimeInterval(-2 * minute),
                isDestructive: false,
                evidence: [],
                diff: [ProposalDiffLine(.add, "+ Upstairs · add room “Office”")],
                state: .staged
            ),
            NilesProposal(
                id: "prop_fix_undone",
                tool: "create_room",
                title: "Create room “Studio”",
                agentName: "Claude Code",
                createdAt: now.addingTimeInterval(-70 * minute),
                isDestructive: false,
                evidence: evidence("Room “Studio” exists"),
                diff: [ProposalDiffLine(.add, "+ Room “Studio”")],
                state: .executed
            ),
            NilesProposal(
                id: "prop_fix_undone_revert",
                tool: "create_room",
                title: "Undo — Create room “Studio”",
                agentName: "Claude Code",
                createdAt: now.addingTimeInterval(-45 * minute),
                isDestructive: false,
                evidence: evidence("No room prop_fix_undone remains"),
                diff: [ProposalDiffLine(.remove, "− Room “Studio”")],
                state: .executed,
                revertsProposalId: "prop_fix_undone"
            ),
            NilesProposal(
                id: "prop_fix_executed",
                tool: "rename_room",
                title: "Rename “Kitchen” to “Cookery”",
                agentName: "Obvious Agent",
                createdAt: now.addingTimeInterval(-25 * minute),
                isDestructive: false,
                evidence: evidence("Room room-2 is named “Cookery”"),
                diff: [ProposalDiffLine(.plain, "Kitchen → Cookery")],
                state: .executed
            ),
        ]

        activityEvents = [
            ActivityEvent(
                at: now.addingTimeInterval(-2 * minute), kind: .staged,
                proposalId: "prop_fix_staged", proposalTitle: "Move Office into Upstairs",
                agentName: "Claude Code"
            ),
            ActivityEvent(
                at: now.addingTimeInterval(-25 * minute), kind: .executed,
                proposalId: "prop_fix_executed", proposalTitle: "Rename “Kitchen” to “Cookery”",
                agentName: "Obvious Agent", detail: "1 of 1 checks confirmed",
                evidence: evidence("Room room-2 is named “Cookery”")
            ),
            ActivityEvent(
                at: now.addingTimeInterval(-28 * minute), kind: .decided,
                proposalId: "prop_fix_executed", proposalTitle: "Rename “Kitchen” to “Cookery”",
                agentName: "Obvious Agent", decision: "approved"
            ),
            ActivityEvent(
                at: now.addingTimeInterval(-30 * minute), kind: .staged,
                proposalId: "prop_fix_executed", proposalTitle: "Rename “Kitchen” to “Cookery”",
                agentName: "Obvious Agent"
            ),
            ActivityEvent(
                at: now.addingTimeInterval(-45 * minute), kind: .executed,
                proposalId: "prop_fix_undone_revert", proposalTitle: "Undo — Create room “Studio”",
                agentName: "Claude Code", detail: "1 of 1 checks confirmed — revert of “Create room “Studio””",
                evidence: evidence("No room prop_fix_undone remains")
            ),
            ActivityEvent(
                at: now.addingTimeInterval(-46 * minute), kind: .undone,
                proposalId: "prop_fix_undone", proposalTitle: "Create room “Studio”",
                agentName: "Claude Code", detail: "Reverted — Undo — Create room “Studio”"
            ),
            ActivityEvent(
                at: now.addingTimeInterval(-70 * minute), kind: .executed,
                proposalId: "prop_fix_undone", proposalTitle: "Create room “Studio”",
                agentName: "Claude Code", detail: "1 of 1 checks confirmed",
                evidence: evidence("Room “Studio” exists")
            ),
            ActivityEvent(
                at: now.addingTimeInterval(-72 * minute), kind: .decided,
                proposalId: "prop_fix_undone", proposalTitle: "Create room “Studio”",
                agentName: "Claude Code", decision: "approved"
            ),
            ActivityEvent(
                at: now.addingTimeInterval(-75 * minute), kind: .staged,
                proposalId: "prop_fix_undone", proposalTitle: "Create room “Studio”",
                agentName: "Claude Code"
            ),
            ActivityEvent(
                at: now.addingTimeInterval(-5 * hour), kind: .executed,
                proposalId: "prop_fix_scene", proposalTitle: "Run scene “Good Morning”",
                agentName: "Claude Code", detail: "1 of 1 checks confirmed"
            ),
            ActivityEvent(
                at: now.addingTimeInterval(-26 * hour), kind: .expired,
                proposalId: "prop_fix_expired", proposalTitle: "Delete room “Storage”",
                agentName: "Obvious Agent", detail: "Expired after 24 hours — never executed"
            ),
        ]
    }
}

#Preview("Activity") {
    ActivityScreen(model: FixtureActivityStore())
}
