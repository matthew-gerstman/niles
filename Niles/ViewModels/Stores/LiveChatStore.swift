import Foundation
import NilesCore
import Observation

/// The in-app chat transcript and its send path — the `ChatViewModel` seam
/// of the former monolithic `LiveNilesStore` (cleanup W3). The runner comes
/// from the agent-status store: the same gated runner Siri composes through.
///
/// This store is self-contained otherwise: no poll fan-out writes here.
@MainActor
@Observable
final class LiveChatStore: ChatViewModel {

    /// The in-app chat transcript, oldest first (spec art_AL0RolQe).
    /// Session-scoped by design: no durable chat log in v1 — durable
    /// outcomes already live in Queue + Activity.
    private(set) var entries: [ChatEntry] = []
    /// Set from the send until the run resolves — the in-flight half of
    /// `canSend`, so the composer disables and a concurrent send is ignored.
    private(set) var isChatRunInFlight = false

    private let agentStatus: LiveAgentStatusStore

    init(agentStatus: LiveAgentStatusStore) {
        self.agentStatus = agentStatus
    }

    // MARK: - ChatViewModel

    /// True when the runner is available and no run is in flight — the
    /// composer's enabled state.
    var canSend: Bool {
        agentStatus.agentRunner != nil && !isChatRunInFlight
    }

    /// One message, one `run(_:)` — identical to Siri, except chat composes
    /// a bounded window of completed transcript rows into the request
    /// (ChatContext). The user row lands optimistically; the agent row runs
    /// until the summary resolves (and staged ids ride the result verbatim)
    /// or the session throws, which renders a failed turn and re-enables
    /// the composer. Concurrent sends are ignored: `canSend` is false from
    /// before the first await.
    func send(_ text: String) async {
        guard canSend, let runner = agentStatus.agentRunner else { return }
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
            "Ask Niles run start: entry=in-app chat request: \\(AgentRunTrace.truncated(request, to: 500), privacy: .public)"
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
}
