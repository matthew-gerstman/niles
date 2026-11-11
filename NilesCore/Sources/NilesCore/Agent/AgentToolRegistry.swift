import Foundation
import MCP

/// The remote-development MCP tools (spec art_rqDQF7Ic §2): one submit
/// surface and two observation tools over the conversation and run traces.
///
/// **MCP-only by construction** — none of these names appear in
/// `NilesToolDispatcher.agentToolOrder`, so the on-device agent's own tool
/// surface (built from the read/write registries alone) can never call its
/// own conversation endpoint. The dispatcher never sees this registry.
///
/// All three follow the read-registry discipline: Codable projections,
/// pretty-printed JSON in both the text and `structuredContent` channels,
/// a 20,000-character response cap enforced with explicit truncation
/// markers, and failures as `isError: true` results that never throw.
///
/// The stores arrive injected (locked decision: not singleton-reached) —
/// the remote conversation store as a reference, the in-app transcript and
/// the trace buffer as entries-provider closures, and the agent runner as
/// a provider. `NilesServerFactory` is the wiring layer.
public struct AgentToolRegistry: Sendable {
    /// The serialized-response ceiling for these tools (~5,000 tokens).
    public static let responseCharacterLimit = 20_000

    private let remoteStore: RemoteConversationStore
    private let inAppTranscript: @Sendable () async -> [ConversationEntry]
    private let traceEntries: @Sendable () async -> [AgentTraceEntry]
    private let runnerProvider: @Sendable () async -> (any AgentRunning)?

    public init(
        remoteStore: RemoteConversationStore,
        inAppTranscript: @escaping @Sendable () async -> [ConversationEntry],
        traceEntries: @escaping @Sendable () async -> [AgentTraceEntry],
        runnerProvider: @escaping @Sendable () async -> (any AgentRunning)?
    ) {
        self.remoteStore = remoteStore
        self.inAppTranscript = inAppTranscript
        self.traceEntries = traceEntries
        self.runnerProvider = runnerProvider
    }

    // MARK: - Tool surface

    public var tools: [Tool] { Self.toolDefinitions }

    public var toolNames: Set<String> { Self.names }

    public static let names: Set<String> = ["agent_chat", "agent_chat_transcript", "run_trace"]

    private static let toolDefinitions: [Tool] = [
        Tool(
            name: "agent_chat",
            description: "Submit one message to Niles' on-device agent — the same agent Siri and the in-app chat use (one agent, one behavior). Returns immediately with {runId, state: \"running\"}; the run proceeds in the background. Read the outcome with agent_chat_transcript (the agent row's text is the run's summary and its stagedProposalIds list what it staged) and inspect every round and tool call with run_trace using the returned runId. Staged proposals wait in the app's Queue for human approval — nothing executes from here. Refuses with an error naming the active entry point when a run is already in flight (single-flight across Siri, in-app chat, and remote). Follow-ups compose the conversation history the same way the in-app chat does.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "message": .object([
                        "type": .string("string"),
                        "description": .string("The message to Niles, in the user's own words."),
                    ]),
                ]),
                "required": .array([.string("message")]),
            ])
        ),
        Tool(
            name: "agent_chat_transcript",
            description: "Read the conversation transcript, oldest first — the in-app chat and the remote agent_chat session, labeled by source. Optional `source`: \"in-app\", \"remote\", or \"all\" (default). Optional `after`: an entry id from a previous page's nextCursor, to continue paging. Responses past the 20,000-character cap carry truncated: true and a nextCursor — never silently shortened. Each row: id, source, role, text, state (running/done/failed), failure copy when failed, stagedProposalIds, timestamp.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "source": .object([
                        "type": .string("string"),
                        "description": .string("\"in-app\", \"remote\", or \"all\" (default)."),
                    ]),
                    "after": .object([
                        "type": .string("string"),
                        "description": .string("Entry id from a previous page's nextCursor — rows after it are returned."),
                    ]),
                ]),
            ]),
            annotations: Tool.Annotations(readOnlyHint: true)
        ),
        Tool(
            name: "run_trace",
            description: "Inspect agent run traces — every model round and tool call, as the app's Agent Trace screen records them. Without `runId`: a lean list of recent runs (runId, entryPoint, entryCount, outcome), newest first. With `runId`: that run's entries in order — kind (runStart/round/toolCall/toolResult/runEnd/error), toolName, argumentsJSON, summary, durationMs, isError. Use the runId agent_chat returned to inspect the run it started. Responses past the 20,000-character cap are truncated explicitly, never silently.",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "runId": .object([
                        "type": .string("string"),
                        "description": .string("The run to deep-read — the id agent_chat returned, or one from the lean run list."),
                    ]),
                ]),
            ]),
            annotations: Tool.Annotations(readOnlyHint: true)
        ),
    ]

    // MARK: - Dispatch

    /// Answers one `tools/call`. Unknown names and failures return `isError`
    /// results rather than throwing.
    public func call(name: String, arguments: [String: Value]? = nil) async -> CallTool.Result {
        switch name {
        case "agent_chat":
            return await agentChat(arguments)
        case "agent_chat_transcript":
            return await transcript(arguments)
        case "run_trace":
            return await runTrace(arguments)
        default:
            let known = Self.names.sorted().joined(separator: ", ")
            return Self.errorResult("Unknown tool \(name). Available agent tools: \(known)")
        }
    }

    private func agentChat(_ arguments: [String: Value]?) async -> CallTool.Result {
        guard let message = arguments?["message"]?.stringValue, !message.isEmpty else {
            return Self.errorResult("Invalid arguments: agent_chat needs a \"message\" string — the message to Niles.")
        }
        guard let runner = await runnerProvider() else {
            return Self.errorResult(
                "The on-device agent is unavailable — the app's agent gate did not pass, so there is no runner to converse with."
            )
        }
        do {
            let runId = try await remoteStore.send(message, runner: runner)
            return Self.result(AgentChatSubmission(runId: runId, state: "running"))
        } catch {
            if case AgentRunError.busy(let entryPoint) = error {
                return Self.errorResult(
                    "A run is already in flight from \(entryPoint). Wait for it to finish, then send again — one run at a time across Siri, in-app chat, and remote."
                )
            }
            return Self.errorResult(AgentRunError.failureMessage(for: error))
        }
    }

    private func transcript(_ arguments: [String: Value]?) async -> CallTool.Result {
        let source = arguments?["source"]?.stringValue ?? "all"
        guard source == "all" || source == "in-app" || source == "remote" else {
            return Self.errorResult("Invalid arguments: source must be \"in-app\", \"remote\", or \"all\".")
        }
        // Both halves are oldest-first snapshots; interleave by timestamp
        // with in-app winning ties, so one dev loop reads chronologically.
        let labeled: [(source: String, entry: ConversationEntry)]
        switch source {
        case "in-app":
            labeled = await Self.labeled("in-app", await inAppTranscript())
        case "remote":
            labeled = await Self.labeled("remote", await remoteStore.transcriptSnapshot())
        default:
            labeled = Self.interleave(
                await Self.labeled("in-app", await inAppTranscript()),
                await Self.labeled("remote", await remoteStore.transcriptSnapshot())
            )
        }
        // Cursor: rows strictly after the named entry id in the interleaved
        // order. An unknown cursor id is a client error, not an empty page —
        // silence would read as "conversation over".
        let eligible: [(source: String, entry: ConversationEntry)]
        if let after = arguments?["after"]?.stringValue {
            guard let index = labeled.firstIndex(where: { $0.entry.id.uuidString == after }) else {
                return Self.errorResult(
                    "Invalid arguments: no entry with id \(after) — use an id from a previous page's nextCursor."
                )
            }
            eligible = Array(labeled[(index + 1)...])
        } else {
            eligible = labeled
        }
        let rows = eligible.map(Self.projection)
        let (page, truncated, nextCursor) = Self.paginate(rows, budget: Self.responseCharacterLimit)
        return Self.result(TranscriptPage(rows: page, truncated: truncated, nextCursor: nextCursor))
    }

    private func runTrace(_ arguments: [String: Value]?) async -> CallTool.Result {
        let entries = await traceEntries()
        guard let runId = arguments?["runId"]?.stringValue else {
            return Self.result(Self.runList(entries, budget: Self.responseCharacterLimit))
        }
        let runEntries = entries.filter { $0.runID == runId }
        guard !runEntries.isEmpty else {
            let known = Self.runList(entries, budget: Self.responseCharacterLimit).runs.map(\.runId).joined(separator: ", ")
            return Self.errorResult("No trace entries for run \(runId). Known runs: \(known)")
        }
        let projections = runEntries.map(Self.projection)
        // Deep reads keep the head and state what was dropped — the cap is
        // never crossed silently, and the dropped count says how much.
        var taken: [TraceEntryProjection] = []
        var used = 0
        for entry in projections {
            let size = Self.encodedSize(entry)
            if used + size > Self.responseCharacterLimit, !taken.isEmpty {
                let detail = TraceRunDetail(
                    runId: runId,
                    entryPoint: runEntries.compactMap(\.entryPoint).first,
                    entries: taken,
                    truncated: true,
                    droppedEntries: projections.count - taken.count
                )
                return Self.result(detail)
            }
            used += size
            taken.append(entry)
        }
        return Self.result(TraceRunDetail(
            runId: runId,
            entryPoint: runEntries.compactMap(\.entryPoint).first,
            entries: taken,
            truncated: false,
            droppedEntries: nil
        ))
    }

    // MARK: - Projections (Codable structs — store types stay untouched)

    /// The `agent_chat` result: the run id to poll with, and the immediate
    /// state. The tool never awaits the run (locked decision 3).
    struct AgentChatSubmission: Codable, Sendable {
        public var runId: String
        public var state: String
    }

    /// One transcript row, source-labeled and flattened for JSON.
    struct TranscriptRow: Codable, Sendable {
        public var id: String
        public var source: String
        public var role: String
        public var text: String
        public var state: String
        public var failure: String?
        public var stagedProposalIds: [String]
        public var timestamp: String
    }

    struct TranscriptPage: Codable, Sendable {
        public var rows: [TranscriptRow]
        public var truncated: Bool
        public var nextCursor: String?
    }

    /// One run in the lean list — enough to pick a run to deep-read.
    struct TraceRunSummary: Codable, Sendable {
        public var runId: String
        public var entryPoint: String?
        public var entryCount: Int
        public var outcome: String
        public var startedAt: String
    }

    struct TraceRunList: Codable, Sendable {
        public var runs: [TraceRunSummary]
        public var truncated: Bool
        public var droppedRuns: Int?
    }

    struct TraceEntryProjection: Codable, Sendable {
        public var id: String
        public var kind: String
        public var toolName: String?
        public var argumentsJSON: String?
        public var summary: String?
        public var durationMs: Double?
        public var isError: Bool
        public var timestamp: String
    }

    struct TraceRunDetail: Codable, Sendable {
        public var runId: String
        public var entryPoint: String?
        public var entries: [TraceEntryProjection]
        public var truncated: Bool
        public var droppedEntries: Int?
    }

    private static func projection(_ labeled: (source: String, entry: ConversationEntry)) -> TranscriptRow {
        let (source, entry) = labeled
        let role = switch entry.role {
        case .user: "user"
        case .agent: "agent"
        }
        let state = switch entry.state {
        case .running: "running"
        case .done: "done"
        case .failed: "failed"
        }
        let failure: String?
        if case .failed(let message) = entry.state {
            failure = message
        } else {
            failure = nil
        }
        return TranscriptRow(
            id: entry.id.uuidString,
            source: source,
            role: role,
            text: entry.text,
            state: state,
            failure: failure,
            stagedProposalIds: entry.stagedProposalIds,
            timestamp: ISOTimestamps.render(entry.timestamp)
        )
    }

    private static func projection(_ entry: AgentTraceEntry) -> TraceEntryProjection {
        let kind = switch entry.kind {
        case .runStart: "runStart"
        case .round: "round"
        case .toolCall: "toolCall"
        case .toolResult: "toolResult"
        case .runEnd: "runEnd"
        case .error: "error"
        }
        return TraceEntryProjection(
            id: entry.id.uuidString,
            kind: kind,
            toolName: entry.toolName,
            argumentsJSON: entry.argumentsJSON,
            summary: entry.summary,
            durationMs: entry.durationMs,
            isError: entry.isError,
            timestamp: ISOTimestamps.render(entry.timestamp)
        )
    }

    /// The lean run list: recent runs, newest first, one line each. Capped
    /// at the 20 most recent runs — older runs are dropped with an explicit
    /// count, never silently.
    private static func runList(_ entries: [AgentTraceEntry], budget: Int) -> TraceRunList {
        var order: [String] = []
        var grouped: [String: [AgentTraceEntry]] = [:]
        for entry in entries {
            if grouped[entry.runID] == nil { order.append(entry.runID) }
            grouped[entry.runID, default: []].append(entry)
        }
        let summaries = order.reversed().prefix(20).map { runId -> TraceRunSummary in
            let run = grouped[runId]!
            let outcome: String
            if let end = run.last(where: { $0.kind == .runEnd }), let summary = end.summary {
                outcome = "done: \(Self.head(summary, to: 200))"
            } else if let error = run.last(where: { $0.kind == .error }), let chain = error.summary {
                outcome = "error: \(Self.head(chain, to: 200))"
            } else {
                outcome = "in flight"
            }
            return TraceRunSummary(
                runId: runId,
                entryPoint: run.compactMap(\.entryPoint).first,
                entryCount: run.count,
                outcome: outcome,
                startedAt: ISOTimestamps.render(run.first?.timestamp ?? Date())
            )
        }
        let dropped = order.count - summaries.count
        return TraceRunList(runs: Array(summaries), truncated: dropped > 0, droppedRuns: dropped > 0 ? dropped : nil)
    }

    // MARK: - Pure helpers

    private static func labeled(_ source: String, _ entries: [ConversationEntry]) -> [(source: String, entry: ConversationEntry)] {
        entries.map { (source, $0) }
    }

    /// Merges two oldest-first labeled lists into one chronological list;
    /// equal timestamps keep in-app first (stable for cursors).
    static func interleave(
        _ inApp: [(source: String, entry: ConversationEntry)],
        _ remote: [(source: String, entry: ConversationEntry)]
    ) -> [(source: String, entry: ConversationEntry)] {
        var merged: [(source: String, entry: ConversationEntry)] = []
        merged.reserveCapacity(inApp.count + remote.count)
        var i = 0, j = 0
        while i < inApp.count || j < remote.count {
            if j >= remote.count {
                merged.append(inApp[i]); i += 1
            } else if i >= inApp.count {
                merged.append(remote[j]); j += 1
            } else if inApp[i].entry.timestamp <= remote[j].entry.timestamp {
                merged.append(inApp[i]); i += 1
            } else {
                merged.append(remote[j]); j += 1
            }
        }
        return merged
    }

    /// Pages rows under the response cap by accumulating per-row encoded
    /// sizes against a budget. Returns the page's rows, whether rows were
    /// held back, and the cursor to resume from. A single row over the
    /// budget has its text truncated so paging always advances.
    static func paginate(
        _ rows: [TranscriptRow],
        budget: Int
    ) -> (rows: [TranscriptRow], truncated: Bool, nextCursor: String?) {
        var taken: [TranscriptRow] = []
        var used = 0
        var index = 0
        while index < rows.count {
            let size = encodedSize(rows[index])
            if used + size > budget { break }
            used += size
            taken.append(rows[index])
            index += 1
        }
        // Nothing fit — the first row alone exceeds the cap. Shrink its text
        // so the page carries it explicitly truncated.
        if taken.isEmpty, let first = rows.first {
            let textBudget = max(0, budget - encodedSize(TranscriptRow(
                id: first.id, source: first.source, role: first.role,
                text: "", state: first.state, failure: first.failure,
                stagedProposalIds: first.stagedProposalIds, timestamp: first.timestamp
            )))
            var shrunk = first
            shrunk.text = String(first.text.prefix(textBudget)) + " … [truncated — this row alone exceeds the response cap; page with its id as after]"
            taken = [shrunk]
            index = 1
        }
        let truncated = index < rows.count
        return (taken, truncated, truncated ? taken.last?.id : nil)
    }

    private static func encodedSize(_ row: TranscriptRow) -> Int {
        (try? encoder.encode(row).count) ?? 0
    }

    private static func encodedSize(_ entry: TraceEntryProjection) -> Int {
        (try? encoder.encode(entry).count) ?? 0
    }

    /// Pretty-printed, key-sorted JSON in both channels — the
    /// search/get_details response idiom.
    private static func result(_ projection: some Codable & Sendable) -> CallTool.Result {
        do {
            let data = try encoder.encode(projection)
            return try CallTool.Result(
                content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
                structuredContent: try Value(projection),
                isError: false
            )
        } catch {
            return errorResult("Failed to serialize the agent tool result: \(error)")
        }
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true
        )
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static func head(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + " …"
    }
}
