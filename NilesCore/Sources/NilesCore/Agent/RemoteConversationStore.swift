import Foundation
import Observation

/// One remote conversation, driven over the LAN MCP server by a paired
/// development client (spec art_rqDQF7Ic §2). Mirrors the in-app chat send
/// path exactly — same composition (ConversationContext), same trace
/// emission, same row states — so a remote repro of an in-app bug
/// exercises the same code instead of a lookalike.
///
/// In-memory only, like the in-app transcript: a run's evidence dies with
/// the app process (locked decision 5). One conversation per gateway — the
/// app is foreground-only and a development client holds one conversation;
/// multi-session support is a later additive extension.
@MainActor
@Observable
public final class RemoteConversationStore {
    /// Oldest first, like the in-app transcript.
    public private(set) var entries: [ConversationEntry] = []

    /// This store's own single-flight half. The app-wide guard lives in
    /// `AgentService` (chat, Siri, and remote all converge there); this one
    /// lets `send` refuse before returning a run id, so the client gets the
    /// busy result on `agent_chat` itself rather than a doomed run.
    private var runInFlight = false

    /// Creates the store off the main actor (the factory wires it from a
    /// nonisolated context); all transcript and run work hops to the main
    /// actor, where the single-flight guard and the trace store live.
    public nonisolated init() {}

    /// A point-in-time copy for the transcript tool — the registry reads
    /// through this instead of reaching into the store's array.
    public func transcriptSnapshot() -> [ConversationEntry] {
        entries
    }

    /// Submits one message and returns the run id immediately; the run
    /// proceeds as a task and its transcript rows resolve in place.
    ///
    /// Throws `AgentRunError.busy` naming the active entry point when a run
    /// is already in flight — here, or on any other entry point (read off
    /// the runner before the submit is accepted). The composed request —
    /// not the raw text — is what the trace records and the agent receives.
    @discardableResult
    public func send(_ text: String, runner: any AgentRunning) async throws -> String {
        if runInFlight {
            throw AgentRunError.busy("Remote MCP")
        }
        // Cross-entry-point pre-check: an in-app or Siri run in flight
        // refuses the submit before a run id is ever minted. A run that
        // starts between this check and the task's call re-loses the race
        // at AgentService's guard — the row then fails with the busy copy,
        // which the transcript still shows.
        if let active = await runner.activeEntryPoint {
            throw AgentRunError.busy(active)
        }
        // Identical to the in-app path: only completed, non-empty rows
        // compose; nil (no history) sends the raw text unchanged.
        let request = ConversationContext.compose(
            current: text,
            history: entries
                .filter { $0.state == .done && !$0.text.isEmpty }
                .map { ($0.role, $0.text) }
        ) ?? text
        // The run id is minted here so the client's agent_chat result and
        // the trace entries it deep-reads correlate (the overload on the
        // trace store exists for exactly this).
        let runId = String(UUID().uuidString.prefix(8)).lowercased()
        AgentRunTraceStore.shared.recordRunStart(runID: runId, entryPoint: "Remote MCP", request: request)
        entries.append(ConversationEntry(id: UUID(), role: .user, text: text))
        let pending = ConversationEntry(id: UUID(), role: .agent, text: "", state: .running)
        entries.append(pending)
        runInFlight = true
        Task {
            // MainActor-isolated (inherits this context); the await hops to
            // the runner and back. Resolution and failure are the shared
            // ConversationTranscript rules — the same ones the composer uses.
            defer { runInFlight = false }
            do {
                let result = try await runner.run(request, entryPoint: "Remote MCP")
                ConversationTranscript.resolve(pending.id, in: &entries, result: result)
            } catch {
                ConversationTranscript.fail(pending.id, in: &entries, with: error)
            }
        }
        return runId
    }
}
