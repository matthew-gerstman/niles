import Foundation
import MCP

/// Builds the per-session MCP `Server` with Niles' full tool surface: the
/// read tools answered in-band and the write tools that stage proposals.
/// One factory per gateway; one server per session, all sharing the same
/// registry pair and proposal store.
public enum NilesServerFactory {

    /// The factory to hand `MCPGateway`. `store` supplies both halves of the
    /// tool surface: its `homeKit` service is the read surface, and its
    /// stage/decide pipeline is the write surface.
    public static func makeFactory(store: ProposalStore) -> MCPGateway.ServerFactory {
        let reads = ReadToolRegistry(service: store.homeKit)
        let writes = WriteToolRegistry(store: store)
        let knownNames = reads.toolNames.union(writes.toolNames)
        return { _ in
            let server = MCP.Server(name: "Niles", version: "0.1.0")
            // Server is an actor: handler registration is an awaited call.
            return await server
                .withMethodHandler(MCP.ListTools.self) { _ in
                    MCP.ListTools.Result(tools: reads.tools + writes.tools)
                }
                .withMethodHandler(MCP.CallTool.self) { params in
                    if reads.toolNames.contains(params.name) {
                        return await reads.call(name: params.name, arguments: params.arguments)
                    }
                    if writes.toolNames.contains(params.name) {
                        return await writes.call(name: params.name, arguments: params.arguments)
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
