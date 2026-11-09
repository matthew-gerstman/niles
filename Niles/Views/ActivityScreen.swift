import SwiftUI
import NilesCore

/// The Activity timeline: the persistent event log as native list rows,
/// sectioned per calendar day, tappable into a detail sheet with the event's
/// structured read-back evidence. Recent executed rows offer Undo as a swipe
/// action; undone entries stay marked Undone.
struct ActivityScreen: View {
    var model: any ActivityViewModel

    @State private var openDetail: ActivityTimeline.Row?
    /// Screenshot hook: `-UIActivityOpenDetail` presents the newest entry's
    /// detail sheet on launch, so per-entry captures need no UI automation.
    @State private var autoOpenedDetail = false

    var body: some View {
        NavigationStack {
            List {
                let rows = ActivityTimeline.rows(events: model.activityEvents, proposals: model.proposals)
                if rows.isEmpty {
                    ContentUnavailableView(
                        "No activity yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Proposals will appear here as they are staged, decided, and executed.")
                    )
                } else {
                    ForEach(ActivityDaySections(rows: rows)) { section in
                        Section(section.title) {
                            ForEach(section.rows) { row in
                                rowView(row)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Activity")
            .sheet(item: $openDetail) { row in
                // Rebuild the row from the model so the sheet reflects undo
                // taps and refreshed evidence, like the approvals sheet does.
                if let fresh = ActivityTimeline.rows(
                    events: model.activityEvents, proposals: model.proposals
                ).first(where: { $0.event.id == row.event.id }) {
                    ActivityDetailView(
                        row: fresh,
                        failure: model.undoFailures[fresh.event.proposalId],
                        onUndo: { model.undo(fresh.event.proposalId) },
                        onDismissFailure: { model.clearUndoFailure(fresh.event.proposalId) }
                    )
                }
            }
            .task {
                if !autoOpenedDetail,
                   ProcessInfo.processInfo.arguments.contains("-UIActivityOpenDetail"),
                   let newest = ActivityTimeline.rows(
                       events: model.activityEvents, proposals: model.proposals
                   ).first {
                    openDetail = newest
                    autoOpenedDetail = true
                }
            }
        }
    }

    private func rowView(_ row: ActivityTimeline.Row) -> some View {
        Button {
            openDetail = row
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: row.verdict.symbol)
                        .foregroundStyle(row.verdict.tint)
                    Text(row.event.proposalTitle)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Text(RelativeTime.label(for: row.event.at))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let detail = row.event.detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(row.verdict.label)
                    .font(.caption)
                    .foregroundStyle(row.verdict.tint)
            }
        }
        .swipeActions(edge: .trailing) {
            if row.undoAvailable {
                Button {
                    model.undo(row.event.proposalId)
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

/// One calendar day of timeline entries, newest first. The view-layer
/// grouping behind the native list headers — the model's recency buckets
/// (Today / Yesterday / This Week / Earlier) stay untouched in the
/// view-model layer this screen's tests pin.
struct ActivityDaySection: Identifiable {
    let title: String
    let rows: [ActivityTimeline.Row]
    var id: String { title }
}

/// Groups timeline rows by calendar day, newest day first, with friendly
/// headers for today and yesterday and abbreviated dates beyond.
struct ActivityDaySections: RandomAccessCollection {
    let sections: [ActivityDaySection]

    init(rows: [ActivityTimeline.Row], calendar: Calendar = .current, now: Date = Date()) {
        var buckets: [(date: Date, rows: [ActivityTimeline.Row])] = []
        for row in rows {
            let day = calendar.startOfDay(for: row.event.at)
            if let index = buckets.firstIndex(where: { $0.date == day }) {
                buckets[index].rows.append(row)
            } else {
                buckets.append((day, [row]))
            }
        }
        sections = buckets.map { bucket in
            ActivityDaySection(title: Self.title(for: bucket.date, calendar: calendar, now: now), rows: bucket.rows)
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

/// The detail sheet behind a tapped entry: the event's facts, structured
/// read-back evidence as a plain native list, the undo's own evidence for
/// undone entries, and any blocked-undo conflict — nothing hand-drawn.
struct ActivityDetailView: View {
    let row: ActivityTimeline.Row
    var failure: ActivityUndoFailure?
    var onUndo: () -> Void = {}
    var onDismissFailure: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Event") {
                    LabeledContent("Status") {
                        HStack(spacing: 4) {
                            Image(systemName: row.verdict.symbol)
                                .foregroundStyle(row.verdict.tint)
                            Text(row.verdict.label)
                        }
                    }
                    LabeledContent("When", value: row.event.at.formatted(date: .abbreviated, time: .standard))
                    LabeledContent("Tool") {
                        Text(row.toolLine)
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if let agent = row.event.agentName {
                        LabeledContent("Agent", value: agent)
                    }
                    if let detail = row.event.detail {
                        Text(detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                if row.verdict == .undone {
                    // The revert's own read-back, linked to the original: the
                    // undo's evidence lives on the revert, not the undone event.
                    Section("Reverted by \(row.revertTitle ?? "a paired revert")") {
                        if row.revertEvidence.isEmpty {
                            Text("The revert's read-back is available while its proposal is in memory.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            evidenceRows(row.revertEvidence)
                        }
                    }
                }
                if !row.event.evidence.isEmpty {
                    Section("Read-back evidence") {
                        let confirmed = row.event.evidence.filter(\.confirmed).count
                        LabeledContent("Confirmed", value: "\(confirmed) of \(row.event.evidence.count) checks")
                        evidenceRows(row.event.evidence)
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
            .navigationTitle(row.event.proposalTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if row.undoAvailable {
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
/// every verdict, an undo, and an unrevertable scene execution.
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
                at: now.addingTimeInterval(-25 * minute, ), kind: .decided,
                proposalId: "prop_fix_executed", proposalTitle: "Rename “Kitchen” to “Cookery”",
                agentName: "Obvious Agent", decision: "approved"
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
                at: now.addingTimeInterval(-70 * minute), kind: .decided,
                proposalId: "prop_fix_undone", proposalTitle: "Create room “Studio”",
                agentName: "Claude Code", decision: "approved"
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
