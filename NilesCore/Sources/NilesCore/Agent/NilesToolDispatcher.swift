import Foundation
import MCP
import os

/// The in-process proxy between the on-device language model and the tool
/// registries. Every tool call the model makes goes through exactly one
/// dispatcher, which:
///
/// - routes the call to `ReadToolRegistry` or `WriteToolRegistry` by name,
/// - enforces a mechanical per-request call budget (exhaustion is an in-band
///   `isError` result, never a thrown error),
/// - caps any single tool response so one read cannot flood the context
///   window, and
/// - records the proposal ids each successful write stages.
///
/// An actor because the model's tool calls can interleave; the budget and the
/// staged-id log must stay exact under concurrency.
public actor NilesToolDispatcher {
    /// One dispatched call, flattened for the toolset layer.
    public struct Outcome: Sendable, Equatable {
        public var text: String
        public var isError: Bool
        /// The proposal this call staged, if it was a successful write.
        public var stagedProposalId: String?
    }

    /// How much of the budget one request may spend across all tools.
    public let budget: Int
    /// Serialized-response ceiling; ~1,000 tokens of text (≈4 chars/token).
    public let responseCharacterLimit: Int

    /// Every call the model attempted, in order. Failed and budget-exhausted
    /// calls are included so the agent can report what actually happened.
    public private(set) var attemptedCalls: [AttemptedCall] = []
    /// Proposal ids staged by successful write calls, in staging order.
    public private(set) var stagedProposalIds: [String] = []
    /// Calls refused because the budget was already spent.
    public private(set) var budgetExhaustions = 0

    public struct AttemptedCall: Sendable, Equatable {
        public var tool: String
        public var isError: Bool
        public var wasBudgetExhausted: Bool
    }

    private let reads: ReadToolRegistry
    private let writes: WriteToolRegistry
    private let readNames: Set<String>
    private let writeNames: Set<String>
    private let proposalIdExtraction: @Sendable (CallTool.Result) -> String?

    /// Every registry tool definition, in registry order — the source of
    /// truth for MCP clients. A fixed snapshot, so the toolset can be built
    /// without entering the actor.
    public let toolDefinitions: [MCP.Tool]

    /// The agent-facing tool surface (art_yvbPAfG9, v9): eight tools in
    /// catalog order. Six adapter tools translate agent vocabulary onto
    /// registry primitives; two registry tools (get_proposal,
    /// assign_accessory_to_room) pass through unchanged. The registries'
    /// full per-type surfaces stay MCP-only.
    public let agentToolDefinitions: [MCP.Tool]

    public static let agentToolOrder = [
        "search", "get_details", "get_proposal",
        "create", "update", "rename", "delete", "assign_accessory_to_room",
    ]

    /// Assembles the agent surface from the six adapter definitions plus
    /// the pass-through registry tools, in catalog order.
    static func assembleAgentTools(reads: [MCP.Tool], writes: [MCP.Tool]) -> [MCP.Tool] {
        let registry = Dictionary(uniqueKeysWithValues: (reads + writes).map { ($0.name, $0) })
        return agentToolOrder.map { name in
            if let adapter = NilesAgentSurface.adapterDefinitions.first(where: { $0.name == name }) {
                return adapter
            }
            guard let passthrough = registry[name] else {
                fatalError("Agent tool \(name) is neither an adapter tool nor a registry tool.")
            }
            return passthrough
        }
    }

    public init(
        reads: ReadToolRegistry,
        writes: WriteToolRegistry,
        budget: Int = NilesToolDispatcher.defaultBudget,
        responseCharacterLimit: Int = NilesToolDispatcher.defaultResponseCharacterLimit
    ) {
        self.reads = reads
        self.writes = writes
        self.readNames = Set(reads.toolNames)
        self.writeNames = Set(writes.toolNames)
        self.budget = budget
        self.responseCharacterLimit = responseCharacterLimit
        self.proposalIdExtraction = Self.proposalId(in:)
        self.toolDefinitions = reads.toolDefinitions + writes.toolDefinitions
        self.agentToolDefinitions = Self.assembleAgentTools(
            reads: reads.toolDefinitions, writes: writes.toolDefinitions
        )
    }

    public static let defaultBudget = 12
    public static let defaultResponseCharacterLimit = 4_000

    /// Dispatches one tool call, logging the run trace around it: the tool
    /// name and the raw arguments as full public JSON before, and the
    /// outcome (result head + total length, or the in-band error summary)
    /// with the duration in ms after. Fires for every entry point — Siri,
    /// in-app chat, and direct MCP dispatch share this one path.
    public func call(name: String, arguments: [String: Value]? = nil) async -> Outcome {
        AgentRunTrace.logger.info(
            "Tool call: \(name, privacy: .public) arguments: \(AgentRunTrace.argumentsJSON(arguments), privacy: .public)"
        )
        let clock = ContinuousClock()
        let startedAt = clock.now
        let outcome = await performCall(name: name, arguments: arguments)
        let duration = startedAt.duration(to: clock.now)
        let durationMs = Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1e15
        AgentRunTrace.logger.info(
            "Tool call finished: \(name, privacy: .public) isError=\(outcome.isError, privacy: .public) durationMs=\(durationMs, privacy: .public) resultLength=\(outcome.text.count, privacy: .public) result: \(AgentRunTrace.truncated(outcome.text, to: 2_000), privacy: .public)"
        )
        return outcome
    }

    /// The dispatch itself, exactly as before the trace wrapper: budget
    /// enforcement first, then routing, then in-band outcome flattening.
    private func performCall(name: String, arguments: [String: Value]? = nil) async -> Outcome {
        if attemptedCalls.count >= budget {
            budgetExhaustions += 1
            attemptedCalls.append(AttemptedCall(tool: name, isError: true, wasBudgetExhausted: true))
            return Outcome(
                text: Self.budgetExhaustedMessage(tool: name, budget: budget),
                isError: true,
                stagedProposalId: nil
            )
        }

        let routed: (result: CallTool.Result, stages: Bool)
        switch name {
        case "search":
            routed = (await Self.searchResult(arguments, reads: reads), false)
        case "get_details":
            routed = (await Self.detailsResult(arguments, reads: reads), false)
        case "create":
            routed = await create(arguments)
        case "update":
            routed = await update(arguments)
        case "rename":
            routed = await rename(arguments)
        case "delete":
            routed = await delete(arguments)
        default:
            // Registry pass-through. Read tools first; the two registries'
            // name sets do not overlap. An unknown name routes to the write
            // registry so the caller sees exactly the error a direct
            // write-registry call would produce.
            if readNames.contains(name) {
                routed = (await reads.call(name: name, arguments: arguments), false)
            } else {
                routed = (await writes.call(name: name, arguments: arguments), true)
            }
        }

        let text = Self.serializedText(of: routed.result, limit: responseCharacterLimit)
        let isError = routed.result.isError == true
        var stagedId: String?
        if routed.stages, !isError {
            stagedId = proposalIdExtraction(routed.result)
            if let stagedId { stagedProposalIds.append(stagedId) }
        } else {
            stagedId = nil
        }
        attemptedCalls.append(AttemptedCall(tool: name, isError: isError, wasBudgetExhausted: false))
        return Outcome(text: text, isError: isError, stagedProposalId: stagedId)
    }

    /// `get_proposal` lives in the write registry but reads state — it stages
    /// nothing, so it must not count as a staged write.
    static let proposalPollToolName = "get_proposal"

    // MARK: - Agent-surface routing (art_yvbPAfG9, v9)

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // Compact and key-sorted: every token a read spends on whitespace is
        // a token of the model's 4,096-token window, and pretty-printed JSON
        // once pushed the home's own name past the response cap.
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static func jsonResult(_ object: some Encodable) -> CallTool.Result {
        do {
            let data = try encoder.encode(object)
            return CallTool.Result(
                content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
                isError: false
            )
        } catch {
            // A read result that cannot be serialized is surfaced, never
            // silently replaced with empty output.
            return agentError("Failed to serialize the read result: \(error)")
        }
    }

    static func agentError(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true
        )
    }

    private static func searchResult(_ arguments: [String: Value]?, reads: ReadToolRegistry) async -> CallTool.Result {
        guard let query = arguments?["query"]?.stringValue, !query.isEmpty else {
            return agentError("search needs a query — the name to look for.")
        }
        do {
            let graph = try await reads.service.snapshot()
            return jsonResult(NilesAgentSurface.search(query: query, graph: graph))
        } catch {
            return agentError("Failed to read the home graph: \(error)")
        }
    }

    private static func detailsResult(_ arguments: [String: Value]?, reads: ReadToolRegistry) async -> CallTool.Result {
        do {
            let graph = try await reads.service.snapshot()
            let details = try NilesAgentSurface.details(
                kind: arguments?["kind"]?.stringValue,
                id: arguments?["id"]?.stringValue,
                graph: graph
            )
            switch details {
            case .leanSummary(let summary): return jsonResult(summary)
            case .fullObject(let object): return jsonResult(object)
            }
        } catch let error as NilesAgentSurface.AgentSurfaceError {
            return agentError(error.message)
        } catch {
            return agentError("Failed to read the home graph: \(error)")
        }
    }

    private func create(_ arguments: [String: Value]?) async -> (CallTool.Result, Bool) {
        guard
            let kindRaw = arguments?["kind"]?.stringValue,
            let kind = NilesAgentSurface.CreateKind(rawValue: kindRaw.lowercased())
        else {
            return (Self.agentError("create needs a kind — room, zone, scene, or group."), false)
        }
        switch kind {
        case .room:
            return (await writes.call(name: "create_room", arguments: arguments), true)
        case .zone:
            return (await writes.call(name: "create_zone", arguments: arguments), true)
        case .scene:
            guard arguments?["actions"]?.arrayValue != nil else {
                return (Self.agentError(
                    "Scene creation needs actions — an array of characteristic writes (accessoryId, characteristic, value)."
                ), false)
            }
            return (await writes.call(name: "create_scene", arguments: arguments), true)
        case .group:
            return await createGroup(arguments)
        }
    }

    /// Group creation speaks accessories; the registry speaks services. The
    /// adapter maps each accessory to its controllable (primary) service and
    /// creates the group with its members in one proposal.
    private func createGroup(_ arguments: [String: Value]?) async -> (CallTool.Result, Bool) {
        guard
            let accessoryIds = NilesAgentSurface.stringList(arguments?["accessoryIds"]),
            !accessoryIds.isEmpty
        else {
            return (Self.agentError("Accessory group creation needs accessoryIds — the accessories to group."), false)
        }
        do {
            let graph = try await reads.service.snapshot()
            let mapping = NilesAgentSurface.controllableServices(for: accessoryIds, graph: graph)
            guard mapping.missing.isEmpty else {
                return (Self.agentError(
                    "No accessory \(mapping.missing.joined(separator: ", ")) — search or get_details for the right id."
                ), false)
            }
            let memberArgs: [String: Value] = [
                "homeId": arguments?["homeId"] ?? .null,
                "name": arguments?["name"] ?? .null,
                "serviceIds": .array(mapping.resolved.map { .string($0) }),
            ]
            return (await writes.call(name: "create_service_group", arguments: memberArgs), true)
        } catch {
            return (Self.agentError("Failed to read the home graph: \(error)"), false)
        }
    }

    private func update(_ arguments: [String: Value]?) async -> (CallTool.Result, Bool) {
        guard let entityId = arguments?["entityId"]?.stringValue, !entityId.isEmpty else {
            return (Self.agentError("update needs entityId."), false)
        }
        let entity: NilesAgentSurface.ResolvedEntity
        let graph: HomeGraph
        do {
            graph = try await reads.service.snapshot()
            guard let resolved = NilesAgentSurface.resolve(entityId: entityId, graph: graph) else {
                return (Self.agentError("No object \(entityId) — use search to find ids."), false)
            }
            entity = resolved
        } catch {
            return (Self.agentError("Failed to read the home graph: \(error)"), false)
        }
        switch entity {
        case .accessoryGroup(_, let groupId, _):
            guard let members = NilesAgentSurface.stringList(arguments?["members"]) else {
                return (Self.agentError("Group update needs members — the complete accessory list."), false)
            }
            let mapping = NilesAgentSurface.controllableServices(for: members, graph: graph)
            guard mapping.missing.isEmpty else {
                return (Self.agentError(
                    "No accessory \(mapping.missing.joined(separator: ", ")) — search or get_details for the right id."
                ), false)
            }
            let memberArgs: [String: Value] = [
                "groupId": .string(groupId),
                "serviceIds": .array(mapping.resolved.map { .string($0) }),
            ]
            return (await writes.call(name: "set_service_group_members", arguments: memberArgs), true)
        case .zone(_, let zoneId, _):
            guard let rooms = NilesAgentSurface.stringList(arguments?["rooms"]) else {
                return (Self.agentError("Zone update needs rooms — the complete room list."), false)
            }
            return (await writes.call(
                name: "set_zone_rooms",
                arguments: ["zoneId": .string(zoneId), "roomIds": .array(rooms.map { .string($0) })]
            ), true)
        case .scene(_, let sceneId, _):
            guard let actions = arguments?["actions"]?.arrayValue else {
                return (Self.agentError("Scene update needs actions — the complete list of characteristic writes."), false)
            }
            return (await writes.call(
                name: "set_scene_actions",
                arguments: ["sceneId": .string(sceneId), "actions": .array(actions)]
            ), true)
        case .trigger:
            return (Self.agentError(
                "Triggers are outside the agent's write surface — automation changes happen through MCP."
            ), false)
        case .room, .accessory:
            return (Self.agentError(
                "update applies to groups, zones, and scenes — nothing to replace on this object."
            ), false)
        }
    }

    private func rename(_ arguments: [String: Value]?) async -> (CallTool.Result, Bool) {
        guard
            let entityId = arguments?["entityId"]?.stringValue, !entityId.isEmpty,
            let newName = arguments?["newName"]?.stringValue, !newName.isEmpty
        else {
            return (Self.agentError("rename needs entityId and newName."), false)
        }
        let entity: NilesAgentSurface.ResolvedEntity
        do {
            guard let resolved = try await resolve(entityId: entityId) else {
                return (Self.agentError("No object \(entityId) — use search to find ids."), false)
            }
            entity = resolved
        } catch {
            return (Self.agentError("Failed to read the home graph: \(error)"), false)
        }
        let (tool, idKey): (String, String)
        switch entity {
        case .room: (tool, idKey) = ("rename_room", "roomId")
        case .zone: (tool, idKey) = ("rename_zone", "zoneId")
        case .scene: (tool, idKey) = ("rename_scene", "sceneId")
        case .accessoryGroup: (tool, idKey) = ("rename_service_group", "groupId")
        case .accessory: (tool, idKey) = ("rename_accessory", "accessoryId")
        case .trigger:
            return (Self.agentError(
                "A trigger's name cannot be changed — HomeKit triggers have no mutable name."
            ), false)
        }
        return (await writes.call(
            name: tool,
            arguments: [idKey: .string(entity.id), "name": .string(newName)]
        ), true)
    }

    private func delete(_ arguments: [String: Value]?) async -> (CallTool.Result, Bool) {
        guard let entityId = arguments?["entityId"]?.stringValue, !entityId.isEmpty else {
            return (Self.agentError("delete needs entityId."), false)
        }
        let entity: NilesAgentSurface.ResolvedEntity
        do {
            guard let resolved = try await resolve(entityId: entityId) else {
                return (Self.agentError("No object \(entityId) — use search to find ids."), false)
            }
            entity = resolved
        } catch {
            return (Self.agentError("Failed to read the home graph: \(error)"), false)
        }
        let (tool, idKey): (String, String)
        switch entity {
        case .room: (tool, idKey) = ("delete_room", "roomId")
        case .zone: (tool, idKey) = ("delete_zone", "zoneId")
        case .scene: (tool, idKey) = ("delete_scene", "sceneId")
        case .accessoryGroup: (tool, idKey) = ("delete_service_group", "groupId")
        case .accessory: (tool, idKey) = ("remove_accessory", "accessoryId")
        case .trigger:
            return (Self.agentError(
                "Triggers are outside the agent's write surface — automation changes happen through MCP."
            ), false)
        }
        return (await writes.call(name: tool, arguments: [idKey: .string(entity.id)]), true)
    }

    private func resolve(entityId: String) async throws -> NilesAgentSurface.ResolvedEntity? {
        let graph = try await reads.service.snapshot()
        return NilesAgentSurface.resolve(entityId: entityId, graph: graph)
    }

    public static func budgetExhaustedMessage(tool: String, budget: Int) -> String {
        "Budget exhausted: the per-request tool budget of \(budget) calls is spent, so \"\(tool)\" was not run. Stop calling tools and report to the user exactly what you completed, what you did not, and why."
    }

    /// Joins the result's text parts — both registries emit a single text
    /// part — and caps the length with an explicit truncation marker.
    static func serializedText(of result: CallTool.Result, limit: Int) -> String {
        let text = result.content.compactMap { part -> String? in
            if case .text(let text) = part { return text.text }
            return nil
        }.joined(separator: "\n")
        guard text.count > limit else { return text }
        let marker = "… [truncated by Niles: response exceeded the \(limit)-character cap; narrow the request (roomId/accessoryId on get_rooms) and call again]"
        return String(text.prefix(limit)) + marker
    }

    /// Successful write results mirror the staged `Proposal` in their
    /// structured content; its `id` is what the runner reports back.
    static func proposalId(in result: CallTool.Result) -> String? {
        guard case .object(let fields) = result.structuredContent else { return nil }
        guard case .string(let id) = fields["id"] else { return nil }
        return id
    }
}
