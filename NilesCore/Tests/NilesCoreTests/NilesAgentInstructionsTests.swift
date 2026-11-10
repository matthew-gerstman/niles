import Foundation
import MCP
import Testing
@testable import NilesCore

/// The finalized compact prompt (art_yvbPAfG9): the instructions template
/// verbatim, plus per-tool one-liners that carry the semantics the staging
/// contract doesn't — DESTRUCTIVE / DEVICE-IMMEDIATE markers, declarative-
/// replace wording, created-DISABLED behavior — with schema-derived arg
/// summaries. The tests keep the compact lines and the agent surface from
/// drifting.
@Suite struct NilesAgentInstructionsTests {
    @Test func templateCarriesTheFullSpecContract() {
        let text = NilesAgentInstructions.text()
        // Role and staging contract.
        #expect(text.contains("configuration agent"))
        #expect(text.contains("stage a proposal"))
        // Name discipline, declarative-replace, destructive ambiguity.
        #expect(text.contains("Resolve ids from reads, never from guesses"))
        #expect(text.contains("search first"))
        #expect(text.contains("ask which one they mean"))
        #expect(text.contains("replace the complete list"))
        #expect(text.contains("stage nothing and explain what you would remove"))
        // Budget and honesty rules.
        #expect(text.contains("Stay within 12 tool calls"))
        #expect(text.contains("report exactly what remains undone"))
        #expect(text.contains("Answer only from tool results"))
        // Dated for the model.
        #expect(text.contains("Today:"))
    }

    @Test func templateBudgetFollowsTheDispatcher() {
        let text = NilesAgentInstructions.text(budget: 7)
        #expect(text.contains("Stay within 7 tool calls"))
    }

    @Test func templateHasNoToolCatalog() {
        let text = NilesAgentInstructions.text()
        // Tools travel with their own descriptions now; the instructions must
        // not enumerate the toolset (that's how the old single-catalog design
        // blew the 4,096-token window). No retired tool name may appear.
        #expect(!text.contains("create_scene"))
        #expect(!text.contains("delete_room"))
        #expect(!text.contains("## Tool catalog"))
        #expect(!text.contains("execute_scene"))
        #expect(!text.contains("set_trigger_state"))
    }

    @Test func templateVariesOnlyByDateLine() {
        let morning = NilesAgentInstructions.text(date: Date(timeIntervalSince1970: 1_762_592_000))
        let evening = NilesAgentInstructions.text(date: Date(timeIntervalSince1970: 1_762_628_000))
        #expect(morning != evening)

        // Everything around the date must be identical: compare the text
        // before "Today: " and the first sentence after it.
        func trimmingDate(_ text: String) -> (before: String, after: String) {
            let head = "Today: "
            let before = String(text[..<text.range(of: head)!.lowerBound])
            let rest = text[text.range(of: head)!.upperBound...]
            let after = String(rest[rest.range(of: "\n")!.lowerBound...])
            return (before, after)
        }
        let a = trimmingDate(morning)
        let b = trimmingDate(evening)
        #expect(a.before == b.before)
        #expect(a.after == b.after)
    }

    // MARK: - Catalog compaction (agent surface)

    private func agentTools() -> [MCP.Tool] {
        let fixture = AgentFixtures.registries()
        return NilesToolDispatcher.assembleAgentTools(
            reads: fixture.reads.toolDefinitions, writes: fixture.writes.toolDefinitions
        )
    }

    private func agentTool(_ name: String) -> MCP.Tool? {
        agentTools().first { $0.name == name }
    }

    /// Tools that must stay off the agent surface (registry-only, MCP-facing).
    private static let offSurfaceTools = [
        "get_homes", "get_rooms", "get_zones", "get_scenes", "get_service_groups", "get_triggers",
        "create_room", "create_zone", "create_scene", "create_service_group",
        "create_timer_trigger", "create_event_trigger",
        "rename_room", "rename_zone", "rename_scene", "rename_service_group", "rename_accessory",
        "delete_room", "delete_zone", "delete_scene", "delete_service_group", "delete_trigger",
        "remove_accessory", "identify_accessory", "unblock_accessory",
        "set_zone_rooms", "set_service_group_members", "set_scene_actions",
        "niles_tool",
        // v9: no control surface, no automation writes on the agent.
        "execute_scene", "write_characteristic", "update_event_trigger", "set_trigger_state",
    ]

    @Test func agentSurfaceIsExactlyTheEightCompactedTools() {
        let tools = agentTools()
        #expect(tools.map(\.name) == NilesToolDispatcher.agentToolOrder)
        #expect(tools.count == 8)
        let surface = Set(tools.map(\.name))
        for excluded in Self.offSurfaceTools {
            #expect(!surface.contains(excluded), "\(excluded) must stay off the agent surface")
        }
    }

    @Test func everyAgentSurfaceToolHasAFinalizedCompactLine() {
        let tools = agentTools()
        for tool in tools {
            let description = NilesToolCatalog.toolDescription(for: tool)
            #expect(!description.isEmpty)
            // No staging boilerplate per tool — the instructions carry it once.
            #expect(!description.contains("STAGES A PROPOSAL"))
            #expect(!description.contains("Poll get_proposal afterwards"))
        }
        // The compact table covers exactly the surface — no orphan lines, no gaps.
        #expect(Set(NilesToolCatalog.compactText.keys) == Set(tools.map(\.name)))
    }

    @Test func compactLinesKeepTheSafetyMarkersTheSurfaceHas() {
        // Marker parity in both directions (registry text spells it lowercase;
        // compare case-insensitively): nothing lost, nothing invented.
        for tool in agentTools() {
            let description = NilesToolCatalog.toolDescription(for: tool)
            for marker in ["destructive", "device-immediate"] {
                #expect(tool.description?.lowercased().contains(marker) == description.lowercased().contains(marker),
                        "marker drift on \(tool.name): \(marker)")
            }
        }
    }

    @Test func compactLinesKeepDeclarativeReplaceAndDestructiveSemantics() throws {
        // v9: no automations on the agent surface, so create carries no
        // created-DISABLED line (that semantics belongs to the MCP-only
        // trigger tools).
        let create = try #require(agentTool("create"))
        #expect(NilesToolCatalog.toolDescription(for: create).contains("accessoryIds"))

        let update = try #require(agentTool("update"))
        #expect(NilesToolCatalog.toolDescription(for: update).contains("complete"))

        let delete = try #require(agentTool("delete"))
        #expect(NilesToolCatalog.toolDescription(for: delete).contains("DESTRUCTIVE"))
    }

    @Test func schemaSummariesListRequiredThenOptionalArguments() throws {
        let create = try #require(agentTool("create"))
        let summary = NilesToolCatalog.schemaSummary(for: create)
        #expect(summary == "args: homeId, kind, name, accessoryIds?, actions?")

        // Optional arguments are suffixed "?" and sorted; required ones come first.
        let getDetails = try #require(agentTool("get_details"))
        #expect(NilesToolCatalog.schemaSummary(for: getDetails) == "args: id?, kind?")

        let rename = try #require(agentTool("rename"))
        #expect(NilesToolCatalog.schemaSummary(for: rename) == "args: entityId, newName")
    }

    @Test func toolDescriptionCarriesTheCompactLineAndArgs() throws {
        let rename = try #require(agentTool("rename"))
        let description = NilesToolCatalog.toolDescription(for: rename)
        #expect(description.hasPrefix("Rename a room, zone, scene, accessory group, or accessory."))
        #expect(description.contains("args:"))
        #expect(!description.contains("STAGES A PROPOSAL"))
    }

    @Test func unknownToolFallsBackToCompactedRegistryDescription() {
        let verbose = MCP.Tool(
            name: "custom_tool",
            description: "Does a thing. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles, and you cannot execute, approve, or deny anything, ever. Poll get_proposal afterwards.",
            inputSchema: .object(["type": .string("object")])
        )
        let description = NilesToolCatalog.toolDescription(for: verbose)
        #expect(description.hasPrefix("Does a thing."))
        #expect(!description.contains("STAGES A PROPOSAL"))
    }

    @Test func catalogStaysWithinItsTokenBudget() {
        // Cheap char-based sanity (chars ÷ 3.5, the draft's own estimate):
        // the whole catalog stays well under the ≈1,600-token fixed surface.
        // The real gate is AgentContextBudgetTests with tokenCount(for:).
        let totalChars = agentTools()
            .map { NilesToolCatalog.toolDescription(for: $0).count }
            .reduce(0, +)
        let estimatedTokens = Double(totalChars) / 3.5
        #expect(estimatedTokens < 1_100, "catalog estimated at \(estimatedTokens) tokens")
    }
}