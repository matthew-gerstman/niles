import Foundation
import MCP

/// Compacts registry tool definitions for the on-device session. The
/// registries are the single source of truth for tool surface and
/// descriptions (art_34OYtrUm): the MCP server lists each description
/// verbatim, and the compact line the model sees here is derived from that
/// same text — the MCP staging boilerplate is stripped (the session
/// instructions state the staging contract once) and an argument summary
/// generated from the tool's own input schema is appended. A missing
/// description degrades to the tool's name, never to empty text. The agent
/// surface is the eight compacted tools — six adapter tools (search,
/// get_details, create, update, rename, delete), whose definitions already
/// carry the shared registry text, plus two pass-through registry tools
/// (get_proposal, assign_accessory_to_room).
public enum NilesToolCatalog {
    /// The session-level tool description: registry text minus staging
    /// boilerplate, plus the schema-derived argument list, e.g.
    /// "Rename a room, zone, scene, accessory group, or accessory by id —
    /// resolve the id with search or get_details first. args: entityId, newName".
    public static func toolDescription(for tool: Tool) -> String {
        let text = compactedRegistryDescription(for: tool)
        let summary = schemaSummary(for: tool)
        return summary.isEmpty ? text : "\(text) \(summary)"
    }

    /// The registry description with the MCP staging boilerplate stripped.
    /// Adapter definitions carry no staging boilerplate — their description
    /// is already the shared registry text — so compaction leaves those
    /// untouched; the coherence tests pin that equality either way.
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
