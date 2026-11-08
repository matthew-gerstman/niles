import Foundation
import MCP

/// The mutating MCP tools: nine declarative write tools plus the
/// `get_proposal` poll. None of them touches HomeKit — a call plans the
/// request against the current graph and stages exactly one proposal
/// (spec: "one agent request is always exactly one approval card"); the
/// human approves or denies on the device, and the agent reads the outcome
/// back through `get_proposal`.
///
/// The transport layer composes this registry alongside `ReadToolRegistry`.
public struct WriteToolRegistry: Sendable {
    private let store: ProposalStore

    public init(store: ProposalStore) {
        self.store = store
    }

    /// The write tools, in listing order.
    public var tools: [Tool] { Self.toolDefinitions }

    /// The names `call` answers: the nine write tools plus `get_proposal`.
    public var toolNames: Set<String> { Set(Self.toolDefinitions.map(\.name)) }

    /// Answers one `tools/call` for a write tool or `get_proposal`. Every
    /// failure — unknown tool, invalid arguments, rejected validation — is an
    /// `isError` result naming what to fix, never a thrown error the agent
    /// cannot see.
    public func call(name: String, arguments: [String: Value]? = nil) async -> CallTool.Result {
        do {
            if name == "get_proposal" {
                guard let id = arguments?["proposalId"]?.stringValue else {
                    throw ProposalStoreError.invalidArguments("Missing required argument “proposalId”.")
                }
                let proposal = try await store.proposal(id: id)
                return try Self.result(proposal, summary: Self.statusSummary(for: proposal))
            }
            let proposal = try await store.stage(tool: name, arguments: arguments)
            return try Self.result(proposal, summary: Self.stagedSummary(for: proposal))
        } catch {
            return Self.errorResult(Self.message(for: error, tool: name))
        }
    }

    // MARK: - Tool definitions

    private static let toolDefinitions: [Tool] = [
        Tool(
            name: "create_room",
            description: "Create a room in a home. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles on the iPhone. Returns the proposal id immediately; poll get_proposal to learn whether it was approved.",
            inputSchema: objectSchema(
                [
                    "homeId": stringProperty("The home to create the room in (from get_homes)."),
                    "name": stringProperty("The new room's name."),
                ],
                required: ["homeId", "name"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "rename_room",
            description: "Rename a room. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                [
                    "roomId": stringProperty("The room to rename (from get_rooms)."),
                    "name": stringProperty("The room's new name."),
                ],
                required: ["roomId", "name"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "delete_room",
            description: "Delete a room. Its accessories move to the default room (HomeKit behavior; the review card says which). DESTRUCTIVE. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                ["roomId": stringProperty("The room to delete (from get_rooms).")],
                required: ["roomId"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false, destructiveHint: true)
        ),
        Tool(
            name: "set_zone_rooms",
            description: "Set a zone's complete room membership — declarative: pass every room the zone should contain; rooms absent from the list are removed, and the review card shows both. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                [
                    "zoneId": stringProperty("The zone to update (from get_zones)."),
                    "roomIds": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Every room the zone should contain (from get_rooms)."),
                    ]),
                ],
                required: ["zoneId", "roomIds"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "create_scene",
            description: "Create a scene (HomeKit action set) whose actions are characteristic writes. Niles stages scenes; it never executes them — running the scene stays in the Home app or Siri. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                [
                    "homeId": stringProperty("The home to create the scene in (from get_homes)."),
                    "name": stringProperty("The new scene's name."),
                    "actions": sceneActionsProperty,
                ],
                required: ["homeId", "name", "actions"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "set_scene_actions",
            description: "Set a scene's complete action list — declarative: actions absent from the list are removed. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                [
                    "sceneId": stringProperty("The scene to update (from get_scenes)."),
                    "actions": sceneActionsProperty,
                ],
                required: ["sceneId", "actions"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "create_service_group",
            description: "Create an empty service group (e.g. 'Desk Lamps'); add members with set_service_group_members. Groups contain services, not accessories. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                [
                    "homeId": stringProperty("The home to create the group in (from get_homes)."),
                    "name": stringProperty("The new group's name."),
                ],
                required: ["homeId", "name"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "set_service_group_members",
            description: "Set a service group's complete membership — declarative: services absent from the list are removed. Service ids come from get_service_groups. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                [
                    "groupId": stringProperty("The group to update (from get_service_groups)."),
                    "serviceIds": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Every service the group should contain (from get_service_groups)."),
                    ]),
                ],
                required: ["groupId", "serviceIds"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "delete_service_group",
            description: "Delete a service group. Devices are unaffected — a group is a label over services. DESTRUCTIVE. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                ["groupId": stringProperty("The group to delete (from get_service_groups).")],
                required: ["groupId"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false, destructiveHint: true)
        ),
        Tool(
            name: "get_proposal",
            description: "Read one proposal's current state: staged/approved/executed/denied/expired/failed, its diff, the recorded evidence after execution, or the error if execution failed. Call this after staging any write to learn the outcome.",
            inputSchema: objectSchema(
                ["proposalId": stringProperty("The proposal id returned by the write tool.")],
                required: ["proposalId"]
            ),
            annotations: Tool.Annotations(readOnlyHint: true)
        ),
    ]

    private static let sceneActionsProperty: Value = .object([
        "type": .string("array"),
        "items": .object([
            "type": .string("object"),
            "properties": .object([
                "accessoryId": .object([
                    "type": .string("string"),
                    "description": .string("The accessory whose service is written (from get_rooms)."),
                ]),
                "service": .object([
                    "type": .string("string"),
                    "description": .string("Optional service name or type; defaults to the accessory's primary service."),
                ]),
                "characteristic": .object([
                    "type": .string("string"),
                    "description": .string("The characteristic type to write, e.g. On or Brightness."),
                ]),
                "value": .object([
                    "description": .string("The target value: number, string, or boolean."),
                ]),
            ]),
            "required": .array([.string("accessoryId"), .string("characteristic"), .string("value")]),
        ]),
        "description": .string("Every characteristic write the scene should perform."),
    ])

    private static func objectSchema(_ properties: [String: Value], required: [String]) -> Value {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
        ])
    }

    private static func stringProperty(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    // MARK: - Result rendering

    private static func result(_ proposal: Proposal, summary: String) throws -> CallTool.Result {
        // One encode for both channels: the text body and the structured
        // content mirror the same ISO-8601 JSON. The SDK's `Value(_:)`
        // conversion would otherwise emit Apple's reference-date doubles,
        // which agents cannot interpret unambiguously.
        let data = try encoder.encode(proposal)
        return try CallTool.Result(
            content: [.text(text: summary + "\n" + String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
            structuredContent: try JSONDecoder().decode(Value.self, from: data),
            isError: false
        )
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true
        )
    }

    private static func stagedSummary(for proposal: Proposal) -> String {
        var lines = [
            "STAGED — nothing has been applied. A human must approve this in Niles on the iPhone.",
            "Proposal \(proposal.id): \(proposal.title)",
        ]
        lines += cardLines(of: proposal)
        let expires = proposal.expiresAt.formatted(.iso8601)
        lines.append(
            "Expires at \(expires). Denial or expiry applies nothing. Poll get_proposal(proposalId: \"\(proposal.id)\") for the outcome."
        )
        return lines.joined(separator: "\n")
    }

    private static func statusSummary(for proposal: Proposal) -> String {
        var lines = ["\(proposal.state.rawValue.uppercased()): \(proposal.title)"]
        for line in cardLines(of: proposal) {
            lines.append(line)
        }
        for evidence in proposal.evidence {
            let mark = evidence.confirmed ? "✓" : "✗"
            lines.append("\(mark) \(evidence.claim) — \(evidence.observed)")
        }
        if let error = proposal.error {
            lines.append("Error: \(error)")
        }
        return lines.joined(separator: "\n")
    }

    private static func cardLines(of proposal: Proposal) -> [String] {
        proposal.card.map { line in
            switch line.kind {
            case .add: "+ \(line.text)"
            case .remove: "− \(line.text)"
            case .note: line.text
            case .plain: "  \(line.text)"
            }
        }
    }

    /// Agent-readable failure text. Validation rejections predate the
    /// proposal, so they always say nothing was staged.
    private static func message(for error: Error, tool: String) -> String {
        switch error {
        case let storeError as ProposalStoreError:
            switch storeError {
            case .unknownTool(let name):
                "Unknown tool \(name). Available write tools: \(Self.toolDefinitions.map(\.name).joined(separator: ", "))."
            case .invalidArguments(let detail):
                detail
            case .validationFailed(let messages):
                "Nothing was staged — validation failed:\n" + messages.map { "- \($0)" }.joined(separator: "\n")
            case .proposalNotFound(let id):
                "No proposal with id \(id)."
            case .proposalNotPending(let id, let state):
                "Proposal \(id) is \(state.rawValue), not pending."
            case .homeReadFailed(let detail):
                "Failed to read the home graph: \(detail)"
            }
        case let plannerError as ProposalPlanner.PlannerError:
            "Nothing was staged: \(plannerError.message)"
        default:
            "Write tool \(tool) failed: \(String(describing: error))"
        }
    }

    /// Pretty-printed, key-sorted, ISO-8601 JSON — stable output for agents
    /// and for diffable test assertions.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
