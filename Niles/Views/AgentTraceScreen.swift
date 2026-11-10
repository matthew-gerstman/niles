import NilesCore
import SwiftUI

/// The on-device Agent Trace viewer: reads `AgentRunTraceStore`'s in-memory
/// buffer — the same emissions the PR #59 os.Log trace writes — and renders
/// each run as an expandable section, newest first. Pure diagnostics: system
/// components only (no chat bubbles, no theme tokens), monospaced for JSON,
/// Dynamic Type throughout.
struct AgentTraceScreen: View {
    @State private var store = AgentRunTraceStore.shared
    @State private var expandedRunIDs: Set<String> = []

    var body: some View {
        Group {
            if store.entries.isEmpty {
                ContentUnavailableView {
                    Label("Agent Trace", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("Agent runs appear here. Ask Niles from Siri or the Home tab, then check back.")
                }
            } else {
                runsList
            }
        }
        .navigationTitle("Agent Trace")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Clear", role: .destructive) {
                    store.clear()
                    expandedRunIDs.removeAll()
                }
                .disabled(store.entries.isEmpty)
            }
        }
    }

    // MARK: - Run grouping

    private struct AgentTraceRun: Identifiable {
        let id: String
        let entries: [AgentTraceEntry]
    }

    /// Runs in buffer order, newest first — entries append oldest-first, so
    /// grouping preserves run order and reversing presents the newest run
    /// at the top.
    private var runs: [AgentTraceRun] {
        var order: [String] = []
        var grouped: [String: [AgentTraceEntry]] = [:]
        for entry in store.entries {
            if grouped[entry.runID] == nil { order.append(entry.runID) }
            grouped[entry.runID, default: []].append(entry)
        }
        return order.reversed().map { AgentTraceRun(id: $0, entries: grouped[$0] ?? []) }
    }

    private var runsList: some View {
        List {
            ForEach(runs) { run in
                runSection(run)
            }
        }
        .onAppear { expandNewestRun() }
        .onChange(of: store.entries.count) { _, _ in expandNewestRun() }
    }

    /// The newest run opens by default (and a run started while the screen
    /// is open opens as it appears); older runs stay collapsed until tapped.
    private func expandNewestRun() {
        if let newest = runs.first {
            expandedRunIDs.insert(newest.id)
        }
    }

    private func runSection(_ run: AgentTraceRun) -> some View {
        DisclosureGroup(isExpanded: expandedBinding(run.id)) {
            ForEach(run.entries) { entry in
                entryRow(entry)
            }
        } label: {
            runHeader(run)
        }
    }

    private func expandedBinding(_ runID: String) -> Binding<Bool> {
        Binding(
            get: { expandedRunIDs.contains(runID) },
            set: { if $0 { expandedRunIDs.insert(runID) } else { expandedRunIDs.remove(runID) } }
        )
    }

    // MARK: - Run header

    /// Header: entry point, request, start time, and end state. Derived from
    /// the run's entries — the run-start entry carries entry point and
    /// request, the last entry the terminal state.
    private func runHeader(_ run: AgentTraceRun) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label(run.entries.first?.entryPoint ?? "Unknown", systemImage: "arrowshape.turn.up.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                endStateBadge(run)
            }
            if let request = run.entries.first?.summary {
                Text(request)
                    .font(.subheadline)
                    .lineLimit(3)
            }
            HStack(spacing: 6) {
                if let start = run.entries.first {
                    Text(start.timestamp, format: .dateTime.month().day().hour().minute().second())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("· run \(run.id)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func endStateBadge(_ run: AgentTraceRun) -> some View {
        switch run.entries.last?.kind {
        case .runEnd:
            Label("Finished", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.green)
        case .error:
            Label("Failed", systemImage: "xmark.circle")
                .font(.caption)
                .foregroundStyle(.red)
        default:
            Label("In flight", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Entries

    @ViewBuilder
    private func entryRow(_ entry: AgentTraceEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Label(Self.kindLabel(entry), systemImage: Self.kindSymbol(entry))
                    .font(.footnote.weight(.medium))
                Spacer()
                if let duration = entry.durationMs {
                    Text(duration, format: .number.precision(.fractionLength(0...1)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text("ms")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .foregroundStyle(entry.isError ? .red : .primary)
            if let args = entry.argumentsJSON {
                Text(args)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let summary = entry.summary, entry.kind != .runStart {
                Text(summary)
                    .font(entry.kind == .toolResult || entry.kind == .error
                        ? .system(.caption, design: .monospaced)
                        : .caption)
                    .foregroundStyle(entry.isError ? .red : .secondary)
                    .textSelection(.enabled)
            }
            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Pure mapping (labels and symbols)

    static func kindLabel(_ entry: AgentTraceEntry) -> String {
        switch entry.kind {
        case .runStart: return "Run started"
        case .round: return "Model round"
        case .toolCall: return "Tool call — \(entry.toolName ?? "unknown")"
        case .toolResult:
            let outcome = entry.isError ? "error" : "ok"
            return "Tool result — \(entry.toolName ?? "unknown") (\(outcome))"
        case .runEnd: return "Run finished"
        case .error: return "Error"
        }
    }

    static func kindSymbol(_ entry: AgentTraceEntry) -> String {
        switch entry.kind {
        case .runStart: return "play.circle"
        case .round: return "brain"
        case .toolCall: return "wrench.and.screwdriver"
        case .toolResult: return entry.isError ? "xmark.circle" : "checkmark.circle"
        case .runEnd: return "flag.checkered"
        case .error: return "exclamationmark.triangle"
        }
    }
}

#Preview("Empty") {
    NavigationStack {
        AgentTraceScreen()
    }
}
