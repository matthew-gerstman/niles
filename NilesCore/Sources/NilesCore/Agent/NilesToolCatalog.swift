import Foundation
import MCP

/// Emits the session's per-tool descriptions: the finalized compact one-liners
/// (art_yvbPAfG9, v7) plus an argument summary generated from the tool's own
/// input schema. The agent surface is the twelve compacted tools — six adapter
/// tools (search, get_details, create, update, rename, delete) and six
/// pass-through registry tools — so the compact table covers exactly those;
/// the registries' full per-type surfaces stay MCP-only. The compact lines
/// carry the same semantics the tests enforce (staging behavior lives once in
/// the instructions; DESTRUCTIVE / DEVICE-IMMEDIATE markers, declarative-
/// replace semantics, and created-DISABLED behavior stay per tool).
public enum NilesToolCatalog {
    /// The finalized compact text per agent-surface tool, keyed by tool name.
    /// Adding an agent-surface tool without a line here fails the catalog tests.
    static let compactText: [String: String] = [
        // Reads
        "search": "Find objects by name across the home: rooms, zones, scenes, accessory groups, triggers, and accessories. The user's words may name any of these; when several match, ask which one they mean.",
        "get_details": "Read home state. No arguments: a lean whole-home summary — homes with counts, rooms with accessory names, zones, scenes, groups, and triggers, without characteristics. With kind and id: one object in full, including its characteristics.",
        "get_proposal": "Read one proposal's state (staged/approved/executed/denied/expired/failed), its diff, execution evidence, or error. Poll after every write.",
        // Writes
        "create": "Create an object: a room, zone, scene, accessory group, timer automation, or event automation. Payload depends on kind: groups take accessoryIds (the members to group); scenes take actions (characteristic writes — Niles never executes scenes); timer automations take fireDate (ISO-8601) and optional recurrence; event automations take events and optional sceneId and executeOnce. Automations are created DISABLED — arming is a separate set_trigger_state approval. Zone names are unique per home.",
        "update": "Replace an object's complete contents: groups take members (accessory ids), zones take rooms, scenes take actions (characteristic writes). Anything absent from the list is removed. Trigger edits use their own tools.",
        "rename": "Rename a room, zone, scene, accessory group, or accessory.",
        "delete": "DESTRUCTIVE. Remove an object from the home: a room, zone, scene, accessory group, trigger, or an accessory. Per-type consequences — where a room's accessories go, which triggers a deleted scene leaves behind — appear on the review card.",
        "execute_scene": "DEVICE-IMMEDIATE. Run a scene now, on approval. An empty scene cannot run.",
        "write_characteristic": "DEVICE-IMMEDIATE. Write one characteristic on approval; the value must fit the characteristic's declared metadata.",
        "update_event_trigger": "Replace an event automation's events (declarative); optionally its end events, recurrences, run-once behavior, or scene. Never changes armed state.",
        "set_trigger_state": "Arm or disarm an automation — enabling is always its own proposal. Also moves a timer's fire date and recurrence.",
        "assign_accessory_to_room": "Move an accessory to a room.",
    ]

    /// The session-level tool description: compact one-liner plus the
    /// schema-derived argument list, e.g.
    /// "Rename a room, zone, scene, accessory group, or accessory. args: entityId, newName".
    /// v7 carries no per-argument source hints: ids come from search and
    /// get_details generally, not from one per-type read.
    /// Unknown tools fall back to the registry description so a missed
    /// compaction entry degrades to verbose, never to empty.
    public static func toolDescription(for tool: Tool) -> String {
        let text = compactText[tool.name] ?? compactedRegistryDescription(for: tool)
        let summary = schemaSummary(for: tool)
        return summary.isEmpty ? text : "\(text) \(summary)"
    }

    /// Mechanical fallback: the registry description with staging boilerplate
    /// stripped (the instructions carry it once).
    static func compactedRegistryDescription(for tool: Tool) -> String {
        var text = tool.description ?? tool.name
        if let markerEnd = text.range(of: "STAGES A PROPOSAL") {
            text = String(text[..<markerEnd.lowerBound])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.last != "." { text += "." }
        return text
    }

    /// "args: entityId, newName" — required properties first and unadorned,
    /// optional properties suffixed "?", names sorted alphabetically within
    /// each group (JSON object keys are unordered).
    public static func schemaSummary(for tool: Tool) -> String {
        guard case .object(let schema) = tool.inputSchema,
              case .object(let definitions)? = schema["properties"] else { return "" }
        var required: Set<String> = []
        if case .array(let requiredValues)? = schema["required"] {
            required = Set(requiredValues.compactMap { value in
                if case .string(let name) = value { return name }
                return nil
            })
        }
        let arguments = definitions.keys
            .sorted { (required.contains($0)) != (required.contains($1)) ? required.contains($0) : $0 < $1 }
            .map { name in required.contains(name) ? name : "\(name)?" }
        if arguments.isEmpty { return "" }
        return "args: " + arguments.joined(separator: ", ")
    }
}
