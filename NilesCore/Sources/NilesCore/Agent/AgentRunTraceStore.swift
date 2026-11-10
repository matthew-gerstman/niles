import Foundation
import Observation

/// One buffered trace entry — the in-memory twin of an `AgentRunTrace`
/// os.Log line, shaped for on-device display. Fields mirror what the log
/// lines carry: when it happened, which run, from which entry point, what
/// kind of event, and the tool/argument/outcome detail when applicable.
public struct AgentTraceEntry: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable, CaseIterable {
        /// The entry point accepted a request and a run is starting.
        case runStart
        /// One model round (respond lifecycle) — start or completion detail.
        case round
        case toolCall
        case toolResult
        /// The run reached its outcome with a summary (no session failure).
        case runEnd
        /// Any error chain on the run path (refusal, session failure, end failure).
        case error
    }

    public let id: UUID
    public let timestamp: Date
    /// Short run identifier correlating the entries of one request; the
    /// viewer groups by it.
    public let runID: String
    /// "Siri" or "In-App Chat" — known only at the entry-point layer, so
    /// entries after the first inherit it from the active run.
    public let entryPoint: String?
    public let kind: Kind
    /// For tool entries: the tool name.
    public let toolName: String?
    /// For tool calls: the raw arguments as public JSON.
    public let argumentsJSON: String?
    /// The human-readable payload: the request, round text, tool result, or
    /// error chain.
    public let summary: String?
    /// For tool results: call duration in milliseconds.
    public let durationMs: Double?
    public let isError: Bool

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        runID: String,
        entryPoint: String? = nil,
        kind: Kind,
        toolName: String? = nil,
        argumentsJSON: String? = nil,
        summary: String? = nil,
        durationMs: Double? = nil,
        isError: Bool = false
    ) {
        self.id = id
        self.timestamp = timestamp
        self.runID = runID
        self.entryPoint = entryPoint
        self.kind = kind
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.summary = summary
        self.durationMs = durationMs
        self.isError = isError
    }
}

/// In-memory twin of the `AgentRunTrace` log stream: every trace emission
/// ALSO appends here (the os.Logger lines are untouched), so the Agent Trace
/// screen can show a whole run without a Console archive. Purely
/// observational — nothing in the run path reads this store.
///
/// Main-actor confinement is the thread safety: emission sites are async
/// contexts off the hot path, so the `await` hop costs nothing and appends
/// serialize. One run is active at a time — chat sends and Siri runs are
/// effectively serialized by the composer's in-flight guard, and in the rare
/// overlap a newer run re-points attribution (timestamps still disambiguate).
/// A diagnostics buffer may approximate here; the run path may not, so no
/// run-path code depends on it.
@MainActor
@Observable
public final class AgentRunTraceStore {
    /// Process-wide singleton: emission sites are spread across NilesCore
    /// and the app layer, so there is exactly one shared buffer.
    public static let shared = AgentRunTraceStore()

    /// Oldest-first; the viewer reverses for display. Capped — drop the
    /// oldest entries beyond the cap so a chatty agent cannot grow the
    /// buffer unboundedly.
    public private(set) var entries: [AgentTraceEntry] = []
    public static let capacity = 300

    /// The run emissions attribute to while no explicit run is given.
    private var activeRun: (id: String, entryPoint: String?)?

    private init() {}

    /// Records a run start and opens a new run for subsequent emissions.
    /// Called by the entry-point layers, where Siri vs in-app chat is known.
    public func recordRunStart(entryPoint: String, request: String) {
        let runID = String(UUID().uuidString.prefix(8)).lowercased()
        activeRun = (runID, entryPoint)
        append(kind: .runStart, entryPoint: entryPoint, summary: request)
    }

    /// One model-round lifecycle line (respond starting / respond finished).
    public func recordRound(_ text: String) {
        append(kind: .round, summary: text)
    }

    /// One tool call, with the arguments exactly as dispatched (public JSON).
    public func recordToolCall(name: String, argumentsJSON: String) {
        append(kind: .toolCall, toolName: name, argumentsJSON: argumentsJSON)
    }

    /// One tool result: outcome text (the same truncated head the log line
    /// carries) plus the call duration.
    public func recordToolResult(name: String, isError: Bool, text: String, durationMs: Double) {
        append(
            kind: .toolResult,
            toolName: name,
            summary: text,
            durationMs: durationMs,
            isError: isError
        )
    }

    /// The run's terminal summary — the result the caller received.
    public func recordRunEnd(summary: String) {
        append(kind: .runEnd, summary: summary)
    }

    /// Any error chain on the run path, in its full reflected form.
    public func recordError(_ chain: String) {
        append(kind: .error, summary: chain, isError: true)
    }

    /// Clears the buffer (the Agent Trace screen's Clear button).
    public func clear() {
        entries.removeAll()
    }

    private func append(
        kind: AgentTraceEntry.Kind,
        toolName: String? = nil,
        argumentsJSON: String? = nil,
        entryPoint: String? = nil,
        summary: String? = nil,
        durationMs: Double? = nil,
        isError: Bool = false
    ) {
        entries.append(AgentTraceEntry(
            runID: activeRun?.id ?? "unattributed",
            entryPoint: entryPoint ?? activeRun?.entryPoint,
            kind: kind,
            toolName: toolName,
            argumentsJSON: argumentsJSON,
            summary: summary,
            durationMs: durationMs,
            isError: isError
        ))
        let overflow = entries.count - Self.capacity
        if overflow > 0 {
            entries.removeFirst(overflow)
        }
    }
}
