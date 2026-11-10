import Foundation
import MCP
import Testing
@testable import NilesCore

/// The finalized compact prompt (art_yvbPAfG9): the instructions template
/// verbatim, plus per-tool one-liners that carry the semantics the staging
/// contract doesn't — DESTRUCTIVE / DEVICE-IMMEDIATE markers, declarative-
/// replace wording, created-DISABLED behavior — with schema-derived arg
/// summaries and source hints. The tests keep the compact lines and the
/// registries from drifting.
@Suite struct NilesAgentInstructionsTests {
    @Test func templateCarriesTheFullSpecContract() {
        let text = NilesAgentInstructions.text()
        // Role and staging contract.
        #expect(text.contains("configuration agent"))
        #expect(text.contains("stage a proposal"))
        // Name discipline, declarative-replace, destructive ambiguity.
        #expect(text.contains("Resolve ids from reads, never from guesses"))
        #expect(text.contains("replace the complete list"))
        #expect(text.contains("stage nothing and explain what you would remove"))
        // Device-immediate and budget and honesty rules.
        #expect(text.contains("devices immediately once approved"))
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
        // blew the 4,096-token window). execute_scene and
        // write_characteristic appear only in the device-immediate rule.
        #expect(!text.contains("create_scene"))
        #expect(!text.contains("delete_room"))
        #expect(!text.contains("## Tool catalog"))
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

    // MARK: - Catalog compaction

    private func allRegistryTools() -> [Tool] {
        let fixture = AgentFixtures.registries()
        return fixture.reads.toolDefinitions + fixture.writes.toolDefinitions
    }

    private func writeTool(_ name: String) -> Tool? {
        allRegistryTools().first { $0.name == name }
    }

    @Test func everyRegistryToolHasAFinalizedCompactLine() {
        let all = allRegistryTools()
        #expect(all.count == 34)
        for tool in all {
            let description = NilesToolCatalog.toolDescription(for: tool)
            #expect(!description.isEmpty)
            // No staging boilerplate per tool — the instructions carry it once.
            #expect(!description.contains("STAGES A PROPOSAL"))
            #expect(!description.contains("Poll get_proposal afterwards"))
        }
        for name in NilesToolCatalog.compactText.keys {
            #expect(all.contains { $0.name == name }, "compact line without a registry tool: \(name)")
        }
    }

    @Test func compactLinesKeepTheSafetyMarkersTheRegistryHas() {
        // Marker parity in both directions: nothing lost, nothing invented.
        for tool in allRegistryTools() {
            let description = NilesToolCatalog.toolDescription(for: tool)
            for marker in ["DESTRUCTIVE", "DEVICE-IMMEDIATE"] {
                #expect(tool.description.contains(marker) == description.contains(marker),
                        "marker drift on \(tool.name): \(marker)")
            }
        }
    }

    @Test func compactLinesKeepDeclarativeReplaceAndCreatedDisabledSemantics() throws {
        let setZoneRooms = try #require(writeTool("set_zone_rooms"))
        #expect(NilesToolCatalog.toolDescription(for: setZoneRooms).contains("complete room list"))
        let createdDisabled = try #require(writeTool("create_timer_trigger"))
        #expect(NilesToolCatalog.toolDescription(for: createdDisabled).contains("Created DISABLED"))
    }

    @Test func schemaSummaryUsesDraftFormatWithSourceHintsAndOptionals() throws {
        let createRoom = try #require(writeTool("create_room"))
        let summary = NilesToolCatalog.schemaSummary(for: createRoom)
        #expect(summary == "args: homeId (from get_homes), name")

        // Optional arguments are suffixed "?".
        let deleteScene = try #require(writeTool("delete_scene"))
        let deleteSceneSummary = NilesToolCatalog.schemaSummary(for: deleteScene)
        #expect(deleteSceneSummary.contains("deleteLinkedTriggers?"))

        // Reads with no required arguments still list them.
        let getRooms = try #require(allRegistryTools().first { $0.name == "get_rooms" })
        let getRoomsSummary = NilesToolCatalog.schemaSummary(for: getRooms)
        #expect(getRoomsSummary.hasPrefix("args: "))
        #expect(getRoomsSummary.contains("detail?"))
    }

    @Test func toolDescriptionCarriesTheCompactLineAndArgs() throws {
        let createRoom = try #require(writeTool("create_room"))
        let description = NilesToolCatalog.toolDescription(for: createRoom)
        #expect(description.hasPrefix("Create a room in a home."))
        #expect(description.contains("args:"))
        #expect(!description.contains("STAGES A PROPOSAL"))
    }

    @Test func unknownToolFallsBackToCompactedRegistryDescription() {
        let verbose = Tool(
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
        // the whole catalog stays near the ≈1,300-token target. The real
        // gate is AgentContextBudgetTests with tokenCount(for:).
        let totalChars = allRegistryTools()
            .map { NilesToolCatalog.toolDescription(for: $0).count }
            .reduce(0, +)
        let estimatedTokens = Double(totalChars) / 3.5
        #expect(estimatedTokens < 1_500, "catalog estimated at \(estimatedTokens) tokens")
    }
}
