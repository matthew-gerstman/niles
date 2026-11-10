import Foundation
import MCP
import Testing
@testable import NilesCore

/// The MCP listing snapshot (art_34OYtrUm, "One description per tool,
/// tested from both sides"): every registered tool on the composed MCP
/// surface carries plain-language description text, deprecated tools carry
/// exactly the marker, the spec's consequences stay stated on the tools
/// that need them, and the agent surface's descriptions are the
/// registries' own text. A registry tool added without plain-language text
/// — or a unified verb given its own diverging text — fails the build here.
@Suite struct ToolSurfaceCoherenceTests {

    private let fixture = AgentFixtures.registries()

    /// The composed MCP listing, in wire order: reads first, then writes —
    /// what the transport wires into `tools/list`.
    private var mcpListing: [MCP.Tool] {
        fixture.reads.toolDefinitions + fixture.writes.toolDefinitions
    }

    private var listingByName: [String: MCP.Tool] {
        Dictionary(uniqueKeysWithValues: mcpListing.map { ($0.name, $0) })
    }

    /// The tools whose text must also serve the on-device agent surface.
    private var agentSurfaceTools: [MCP.Tool] {
        NilesToolDispatcher.assembleAgentTools(
            reads: fixture.reads.toolDefinitions, writes: fixture.writes.toolDefinitions
        )
    }

    // MARK: - MCP listing snapshot

    @Test func listingShapeIsPinned() {
        // The full registered surface, in order. Consolidated tools first
        // within each registry, then the deprecated per-type predecessors.
        #expect(
            mcpListing.map(\.name)
                == [
                    // Reads
                    "search", "get_details",
                    "get_homes", "get_rooms", "get_zones", "get_scenes", "get_service_groups", "get_triggers",
                    // Writes: unified verbs
                    "rename", "delete", "create", "update",
                    // Writes: deprecated per-type predecessors
                    "create_room", "rename_room", "delete_room",
                    "set_zone_rooms", "create_zone", "rename_zone", "delete_zone",
                    "create_scene", "set_scene_actions", "rename_scene", "delete_scene",
                    "execute_scene", "write_characteristic",
                    "create_service_group", "rename_service_group", "set_service_group_members",
                    "delete_service_group",
                    "create_timer_trigger", "create_event_trigger", "update_event_trigger",
                    "set_trigger_state", "delete_trigger",
                    "rename_accessory", "identify_accessory", "assign_accessory_to_room",
                    "unblock_accessory", "remove_accessory", "get_proposal",
                ]
        )
    }

    @Test func everyRegisteredToolHasPlainLanguageDescription() {
        for tool in mcpListing {
            let description = tool.description
            #expect(description != nil, "\(tool.name) must ship a description — the registries are the single source of truth for tool text")
            guard let description, !description.isEmpty else { continue }
            // No truncated configuration meta-language ("STAG…"-style
            // fragments) — the text must read to a human, in full.
            #expect(!description.contains("STAG…"), "\(tool.name) carries truncated meta-language")
            #expect(!description.lowercased().contains("lean by default"), "\(tool.name) carries configuration meta-language")
        }
    }

    @Test func deprecatedMarkerSitsOnExactlyThePerTypePredecessors() {
        let expectedDeprecated: Set<String> = [
            // Reads
            "get_homes", "get_rooms", "get_zones", "get_scenes", "get_service_groups", "get_triggers",
            // Writes
            "create_room", "rename_room", "delete_room",
            "set_zone_rooms", "create_zone", "rename_zone", "delete_zone",
            "create_scene", "set_scene_actions", "rename_scene", "delete_scene",
            "create_service_group", "rename_service_group", "set_service_group_members",
            "delete_service_group",
            "create_timer_trigger", "create_event_trigger", "update_event_trigger",
            "delete_trigger", "rename_accessory", "remove_accessory",
        ]
        for tool in mcpListing {
            let deprecated = tool.description?.contains("DEPRECATED") == true
            #expect(
                deprecated == expectedDeprecated.contains(tool.name),
                "\(tool.name): DEPRECATED marker \(deprecated ? "unexpected" : "missing")"
            )
        }
        #expect(expectedDeprecated.count == 27)
    }

    // MARK: - Spec consequences stay stated on the tools that need them

    @Test func descriptionsCarryTheSpecConsequences() {
        let byName = listingByName
        func description(_ name: String) -> String { byName[name]?.description ?? "" }

        // Declarative-replace consequences on the declarative tools.
        for name in ["update", "set_zone_rooms", "set_scene_actions", "set_service_group_members"] {
            #expect(
                description(name).lowercased().contains("absent from the list"),
                "\(name) must state the declarative-replace consequence"
            )
        }
        // Device-immediate markers on the two control tools.
        for name in ["execute_scene", "write_characteristic"] {
            #expect(
                description(name).contains("device-immediate"),
                "\(name) must carry the device-immediate marker"
            )
        }
        // The automation-arming invariant on the trigger tools.
        let armingInvariant: [String: String] = [
            "create": "created disabled",
            "update": "arming is always its own proposal",
            "create_timer_trigger": "created disabled",
            "create_event_trigger": "created disabled",
            "update_event_trigger": "arming stays a separate",
            "set_trigger_state": "always a separate proposal",
        ]
        for (name, fragment) in armingInvariant {
            #expect(
                description(name).lowercased().contains(fragment),
                "\(name) must state the arming invariant — missing fragment: \(fragment)"
            )
        }
    }

    // MARK: - Two-sided coherence

    @Test func agentSurfaceDescriptionsAreTheRegistryText() {
        // Both projections read one source: with the MCP staging boilerplate
        // stripped, each agent tool's description is identical to its
        // registry twin's text. A unified verb given its own diverging text,
        // or an adapter description that drifts from the shared static,
        // fails here. (Pass-through tools carry the staging suffix in both
        // listings — the MCP server lists the registry text verbatim — so
        // the comparison strips it from both sides.)
        let registry = listingByName
        for tool in agentSurfaceTools {
            guard let registryTool = registry[tool.name] else {
                Issue.record("\(tool.name) has no registry twin — the agent surface must project registered tools")
                continue
            }
            let compacted = NilesToolCatalog.compactedRegistryDescription(for: registryTool)
            #expect(
                NilesToolCatalog.compactedRegistryDescription(for: tool) == compacted,
                "\(tool.name): agent description diverges from the registry text"
            )
        }
    }
}
