import Foundation
import MCP

/// Emits the session's per-tool descriptions: the finalized compact one-liners
/// (art_yvbPAfG9) plus an argument summary generated from the registry's own
/// input schema. The registry stays the source of truth for what a tool does —
/// the compact lines carry the same semantics (staging behavior lives once in
/// the instructions; DESTRUCTIVE / DEVICE-IMMEDIATE markers, declarative-
/// replace semantics, and created-DISABLED behavior stay per tool) — and the
/// tests enforce that the two never drift.
public enum NilesToolCatalog {
    /// The finalized compact text per tool, keyed by registry tool name.
    /// Adding a registry tool without a line here fails the catalog tests.
    static let compactText: [String: String] = [
        // Reads
        "get_homes": "List every home with counts of its rooms, zones, accessories, scenes, service groups, and triggers, plus home hub state and HomeKit authorization. Call first for home IDs.",
        "get_rooms": "List rooms with accessories, services, and characteristics (values + declared metadata). Lean by default; scope by room or accessory, or request detail. Check before staging a characteristic write.",
        "get_zones": "List zones with their member rooms.",
        "get_scenes": "List scenes with their characteristic-write actions and last execution date.",
        "get_service_groups": "List service groups — services, not accessories — with member services.",
        "get_triggers": "List automations: enabled state, activation state, timer fire date and recurrence, event triggers with events and predicate.",
        "get_proposal": "Read one proposal's state (staged/approved/executed/denied/expired/failed), its diff, execution evidence, or error. Poll after every write.",
        // Writes
        "create_room": "Create a room in a home.",
        "rename_room": "Rename a room.",
        "delete_room": "DESTRUCTIVE. Delete a room; its accessories move to the default room — the card says which.",
        "set_zone_rooms": "Set a zone's complete room list; rooms absent from the list are removed.",
        "create_zone": "Create an empty zone; zone names are unique per home.",
        "rename_zone": "Rename a zone; its rooms are unaffected.",
        "delete_zone": "DESTRUCTIVE. Delete the zone grouping only; its rooms survive.",
        "create_scene": "Create a scene whose actions are characteristic writes (actions array). Niles never executes scenes.",
        "set_scene_actions": "Replace a scene's complete action list; actions absent from the list are removed.",
        "rename_scene": "Rename a scene; scene names are unique across homes.",
        "delete_scene": "DESTRUCTIVE. Linked triggers survive but run nothing — the card names them; deleteLinkedTriggers deletes them too.",
        "execute_scene": "DEVICE-IMMEDIATE. Run a scene now, on approval. HomeKit refuses to execute an empty scene.",
        "write_characteristic": "DEVICE-IMMEDIATE. Write one characteristic on approval; the value must fit the characteristic's declared metadata.",
        "create_service_group": "Create an empty group of services.",
        "rename_service_group": "Rename a service group; its members are unaffected.",
        "set_service_group_members": "Set a group's complete service list; services absent from the list are removed.",
        "delete_service_group": "DESTRUCTIVE. Delete the group label; devices are unaffected.",
        "create_timer_trigger": "Create a timer automation. Created DISABLED — arming is a separate set_trigger_state approval.",
        "create_event_trigger": "Create an event automation — characteristic and/or presence events, optional endEvents restore-after-duration and executeOnce. Created DISABLED.",
        "update_event_trigger": "Replace an event trigger's events (declarative); optionally its endEvents, recurrences, executeOnce, or scene. Never changes armed state.",
        "set_trigger_state": "Arm or disarm a trigger — enabling is always its own proposal. Also moves a timer's fireDate/recurrence.",
        "delete_trigger": "DESTRUCTIVE. Delete an automation; it stops firing immediately.",
        "rename_accessory": "Rename an accessory across HomeKit.",
        "identify_accessory": "Flash or beep the accessory so a human can spot it. Rejected when it has no Identify capability.",
        "assign_accessory_to_room": "Move an accessory to a room.",
        "unblock_accessory": "Unblock an accessory HomeKit has blocked.",
        "remove_accessory": "DESTRUCTIVE. Remove an accessory: its services leave their groups, its scene actions die, triggers watching its characteristics stop. The card lists every affected object.",
    ]

    /// Where an id argument comes from, so the model never guesses a source.
    private static let sourceHints: [String: String] = [
        "homeId": "from get_homes",
        "roomId": "from get_rooms",
        "accessoryId": "from get_rooms",
        "zoneId": "from get_zones",
        "sceneId": "from get_scenes",
        "groupId": "from get_service_groups",
        "triggerId": "from get_triggers",
        "proposalId": "from get_proposal or a write result",
    ]

    /// The session-level tool description: compact one-liner plus the
    /// schema-derived argument list with source hints, e.g.
    /// "Create a room in a home. args: homeId (from get_homes), name".
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
        var text = tool.description
        if let markerEnd = text.range(of: "STAGES A PROPOSAL") {
            text = String(text[..<markerEnd.lowerBound])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.last != "." { text += "." }
        return text
    }

    /// "args: homeId (from get_homes), name" — required properties first and
    /// unadorned, optional properties suffixed "?", in schema order.
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
            .map { name -> String in
                let hint = sourceHints[name].map { " (\($0))" } ?? ""
                let optional = required.contains(name) ? "" : "?"
                return "\(name)\(hint)\(optional)"
            }
        if arguments.isEmpty { return "" }
        return "args: " + arguments.joined(separator: ", ")
    }
}
