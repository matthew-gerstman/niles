import Foundation
import MCP

/// Builds the per-session MCP `Server` with Niles' full tool surface: the
/// read tools answered in-band and the write tools that stage proposals.
/// One factory per gateway; one server per session, all sharing the same
/// registry pair and proposal store.
public enum NilesServerFactory {

    /// The factory to hand `MCPGateway`. `store` supplies both halves of the
    /// tool surface: its `homeKit` service is the read surface, and its
    /// stage/decide pipeline is the write surface. The optional providers
    /// light up the remote-conversation surface (spec art_rqDQF7Ic §2):
    /// `runnerProvider` hands the app's gated agent runner to `agent_chat`,
    /// `inAppTranscriptProvider` lets `agent_chat_transcript` read the
    /// in-app chat. Without them the registry still serves — the submit
    /// answers in-band that the agent is unavailable, and the transcript
    /// shows the remote conversation alone.
    public static func makeFactory(
        store: ProposalStore,
        runnerProvider: (@Sendable () async -> (any AgentRunning)?)? = nil,
        inAppTranscriptProvider: (@Sendable () async -> [ConversationEntry])? = nil
    ) -> MCPGateway.ServerFactory {
        let reads = ReadToolRegistry(service: store.homeKit)
        let writes = WriteToolRegistry(store: store)
        // One remote conversation per gateway — the app is foreground-only
        // and this change ships one development client (the blueprint's
        // resolved open question). The trace buffer arrives as an
        // entries-provider closure at the wiring layer; the registry never
        // reaches the singleton itself.
        let agents = AgentToolRegistry(
            remoteStore: RemoteConversationStore(),
            inAppTranscript: inAppTranscriptProvider ?? { [] },
            traceEntries: { await AgentRunTraceStore.shared.entries },
            runnerProvider: runnerProvider ?? { nil }
        )
        let knownNames = reads.toolNames.union(writes.toolNames).union(agents.toolNames)
        return { _ in
            let server = MCP.Server(name: "Niles", version: "0.1.0")
            // Server is an actor: handler registration is an awaited call.
            return await server
                .withMethodHandler(MCP.ListTools.self) { _ in
                    MCP.ListTools.Result(tools: reads.tools + writes.tools + agents.tools)
                }
                .withMethodHandler(MCP.CallTool.self) { params in
                    if reads.toolNames.contains(params.name) {
                        return await reads.call(name: params.name, arguments: params.arguments)
                    }
                    if writes.toolNames.contains(params.name) {
                        return await writes.call(name: params.name, arguments: params.arguments)
                    }
                    if agents.toolNames.contains(params.name) {
                        return await agents.call(name: params.name, arguments: params.arguments)
                    }
                    let sorted = knownNames.sorted().joined(separator: ", ")
                    return CallTool.Result(
                        content: [
                            .text(
                                text: "Unknown tool \(params.name). Available tools: \(sorted)",
                                annotations: nil,
                                _meta: nil
                            )
                        ],
                        isError: true
                    )
                }
        }
    }
}
