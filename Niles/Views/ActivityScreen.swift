import SwiftUI
import NilesCore

/// The Activity timeline: one row per proposal, sectioned per calendar day.
/// The persistent event log is grouped by proposal id at the view layer, so
/// a proposal's staged / approved / executed history collapses into a single
/// card showing its human-readable summary, current lifecycle state, and
/// most recent timestamp. Tapping opens a detail view with the full
/// lifecycle timeline and structured read-back evidence. Recent executed
/// rows offer Undo as a swipe action; undone entries stay marked Undone.
struct ActivityScreen: View {
    var model: any ActivityViewModel

    /// Title mode for this pane's bar — inline in the wide layout (set by
    /// widePane()), automatic in the narrow layout. See ContentView.
    @Environment(\.widePaneTitleMode) private var widePaneTitleMode
    @State private var openDetail: ActivityTimeline.Group?
    /// Screenshot hook: `-UIActivityOpenDetail` presents the newest proposal's
    /// detail sheet on launch, so per-proposal captures need no UI automation.
    @State private var autoOpenedDetail = false

    var body: some View {
        NavigationStack {
            List {
                let groups = ActivityTimeline.groups(events: model.activityEvents, proposals: model.proposals)
                if groups.isEmpty {
                    ContentUnavailableView(
                        "No activity yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Proposals will appear here as they are staged, decided, and executed.")
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
            .navigationTitle("Activity")
            // Shared bar modifier (bisect cell 3, diagnosis art_LwUDWPuP):
            // in the wide layout the leading pane never registers the top
            // scroll-edge effect — the system status pillar sits over the
            // trailing pane's x-range — so its bar falls back to the legacy
            // expanded large-title geometry (110 pt, title below an empty
            // 58 pt inline zone). Each pane applies the shared title mode
            // from widePane()'s environment — inline in the wide layout,
            // automatic (untouched) in the narrow layout.
            .navigationBarTitleDisplayMode(widePaneTitleMode)
            // Margins belong on the List, not on the NavigationStack
            // wrapper (widePane): margins scoped to the stack interfere
            // with the bar's scroll-edge tracking in the wide layout
            // (bisect cell 2, diagnosis art_LwUDWPuP).
            .contentMargins(.horizontal, 20, for: .scrollContent)
            .sheet(item: $openDetail) { group in
                // Rebuild the group from the model so the sheet reflects undo
                // taps and refreshed evidence, like the approvals sheet does.
                if let fresh = ActivityTimeline.groups(
                    events: model.activityEvents, proposals: model.proposals
                ).first(where: { $0.proposalId == group.proposalId }) {
                    ActivityDetailView(
                        group: fresh,
                        failure: model.undoFailures[fresh.proposalId],
                        onUndo: { model.undo(fresh.proposalId) },
                        onDismissFailure: { model.clearUndoFailure(fresh.proposalId) }
                    )
                }
            }
            .task {
                if !autoOpenedDetail,
                   ProcessInfo.processInfo.arguments.contains("-UIActivityOpenDetail"),
                   let newest = ActivityTimeline.groups(
                       events: model.activityEvents, proposals: model.proposals
                   ).first {
                    openDetail = newest
                    autoOpenedDetail = true
                }
            }
        }
    }

    private func groupRow(_ group: ActivityTimeline.Group) -> some View {
        Button {
            openDetail = group
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: group.state.symbol)
                    .foregroundStyle(group.state.tint)
                VStack(alignment: .leading, spacing: 4) {
                    // The human-readable summary is the headline; the tool
                    // name and prop_ id live in the detail sheet only.
                    Text(group.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(RelativeTime.label(for: group.latestAt))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .swipeActions(edge: .trailing) {
            if group.undoAvailable {
                Button {
                    model.undo(group.proposalId)
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
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
        }
    }

    /// System status colors by meaning: red reserved for denial and failure,
    /// gray for the terminal-but-neutral expired and undone states.
    var tint: Color {
        switch self {
        case .staged: .orange
        case .approved, .executed: .green
        case .denied, .failed: .red
        case .expired, .undone: .secondary
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
    var onUndo: () -> Void = {}
    var onDismissFailure: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
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
            }
            .navigationTitle(group.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if group.undoAvailable {
                        Button("Undo", systemImage: "arrow.uturn.backward") {
                            onUndo()
                        }
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
                Image(systemName: item.confirmed ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(item.confirmed ? Color.green : Color.red)
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
    var undoFailures: [String: ActivityUndoFailure] = [:]

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
