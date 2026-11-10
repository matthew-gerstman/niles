import Foundation
import MCP
import XCTest
#if canImport(FoundationModels)
import FoundationModels
@testable import NilesCore

/// Scripted-model runs of the full agent loop: a custom LanguageModel that
/// replays a fixed turn script — one tool call per turn, then a final text —
/// so the acceptance scenarios run deterministically with no on-device model,
/// through the production runner (`NilesAgent.run(_:using:)`).
///
/// The custom LanguageModel/executor conformance is iOS 27+; on older
/// runtimes these tests report skipped rather than failing.
@available(iOS 27.0, *)
private struct ScriptedTurn: Hashable, Sendable {
    /// One tool call per turn: name plus arguments as JSON.
    var toolName: String?
    var argumentsJSON: String?
    var finalText: String

    static func call(_ tool: String, _ argumentsJSON: String) -> ScriptedTurn {
        ScriptedTurn(toolName: tool, argumentsJSON: argumentsJSON, finalText: "")
    }
    static func done(_ text: String) -> ScriptedTurn {
        ScriptedTurn(toolName: nil, argumentsJSON: nil, finalText: text)
    }
}

private struct ScriptedExecutorConfiguration: Hashable, Sendable {
    var turns: [ScriptedTurn]
}

@available(iOS 27.0, *)
private struct ScriptedLanguageModel: LanguageModel {
    typealias Executor = ScriptedExecutor
    var configuration: ScriptedExecutorConfiguration

    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.toolCalling])
    }

    var executorConfiguration: ScriptedExecutorConfiguration { configuration }
}

@available(iOS 27.0, *)
private struct ScriptedExecutor: LanguageModelExecutor {
    typealias Model = ScriptedLanguageModel

    let configuration: ScriptedExecutorConfiguration

    init(configuration: ScriptedExecutorConfiguration) throws {
        self.configuration = configuration
    }

    func prewarm(model: ScriptedLanguageModel, transcript: Transcript) {}

    func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: ScriptedLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        // Each generation corresponds to one tool-call turn or the final
        // response; count the ones already in the transcript. One tool call
        // per scripted turn keeps this indexing exact. Transcript is a
        // RandomAccessCollection, not an `entries` property.
        let completed = request.transcript.filter { entry in
            switch entry {
            case .toolCalls, .response: return true
            default: return false
            }
        }.count
        let turns = model.configuration.turns
        guard completed < turns.count else {
            // Script exhausted: emit nothing further rather than loop forever.
            await channel.send(.response(action: .appendText("", tokenCount: 0)))
            return
        }
        let turn = turns[completed]
        if let name = turn.toolName, let argumentsJSON = turn.argumentsJSON {
            await channel.send(.toolCalls(action: .toolCall(
                id: UUID().uuidString,
                name: name,
                action: .appendArguments(argumentsJSON, tokenCount: argumentsJSON.count / 4)
            )))
        } else {
            await channel.send(.response(action: .appendText(turn.finalText, tokenCount: turn.finalText.count / 4)))
        }
    }
}

@available(iOS 27.0, *)
final class AgentScriptedModelTests: XCTestCase {
    private func makeAgent(
        budget: Int = NilesToolDispatcher.defaultBudget,
        graph: HomeGraph = AgentFixtures.graph()
    ) -> (agent: NilesAgent, store: ProposalStore, dispatcher: NilesToolDispatcher, service: FakeHomeKitService) {
        let fixture = AgentFixtures.registries(graph: graph)
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes, budget: budget)
        return (NilesAgent(dispatcher: dispatcher), fixture.store, dispatcher, fixture.service)
    }

    private func run(
        _ agent: NilesAgent, turns: [ScriptedTurn], request: String
    ) async throws -> NilesAgent.Outcome {
        let model = ScriptedLanguageModel(configuration: ScriptedExecutorConfiguration(turns: turns))
        return try await agent.run(request, using: model)
    }

    // MARK: - Living-room lights to 30%

    func testLivingRoomLightsTo30PercentStagesOneCreateSceneProposal() async throws {
        let (agent, store, _) = makeAgent()

        let outcome = try await run(
            agent,
            turns: [
                .call("get_details", "{}"),
                .call("create", """
                {"kind": "scene", "homeId": "home-1", "name": "Living Room 30%", "actions": [
                    {"accessoryId": "acc-lr-1", "characteristic": "Brightness", "value": 30},
                    {"accessoryId": "acc-lr-2", "characteristic": "Brightness", "value": 30},
                    {"accessoryId": "acc-lr-3", "characteristic": "Brightness", "value": 30}
                ]}
                """),
                .done("I staged one proposal for your review in Niles: \u{201C}Living Room 30%\u{201D} sets all three Living Room lamps to 30% brightness. Nothing is applied until you approve it."),
            ],
            request: "Set the living room lights to 30%."
        )

        let proposals = await store.allProposals()
        XCTAssertEqual(proposals.count, 1, "exactly one create_scene proposal must be staged")
        let proposal = try XCTUnwrap(proposals.first)
        XCTAssertEqual(proposal.tool, "create_scene")
        XCTAssertEqual(proposal.title, "Create scene \u{201C}Living Room 30%\u{201D}")
        XCTAssertEqual(proposal.summary, "Create scene \u{201C}Living Room 30%\u{201D} with 3 actions")

        // Correct arguments: one action per Living Room light, Brightness 30
        // (the fixture's metadata range is 0-100).
        let actionLines = proposal.card.map(\.text).filter { $0.contains("Brightness") }
        XCTAssertEqual(actionLines, [
            "Living Room Lamp 1: Brightness \u{2192} 30",
            "Living Room Lamp 2: Brightness \u{2192} 30",
            "Living Room Lamp 3: Brightness \u{2192} 30",
        ])

        XCTAssertEqual(outcome.stagedProposalIds, [proposal.id])
        XCTAssertTrue(outcome.summary.contains("staged one proposal"))
    }

    // MARK: - Grouping three lights into one accessory group

    func testGroupingThreeLightsStagesOnePopulatedGroupProposal() async throws {
        let (agent, store, _, service) = makeAgent()

        let outcome = try await run(
            agent,
            turns: [
                .call("get_details", "{}"),
                .call("create", """
                {"kind": "group", "homeId": "home-1", "name": "Hydra",
                 "accessoryIds": ["acc-lr-1", "acc-lr-2", "acc-lr-3"]}
                """),
                .done("I staged one proposal: the group \u{201C}Hydra\u{201D} with the three Living Room lamps."),
            ],
            request: "Group the three Hydra lights into one lamp called Hydra."
        )

        // One proposal, and it is the registry's create_service_group — the
        // adapter resolved the accessories to their primary services.
        let proposals = await store.allProposals()
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(proposals.first?.tool, "create_service_group")
        XCTAssertEqual(proposals.first?.summary, "Create service group \u{201C}Hydra\u{201D} with 3 members")
        XCTAssertEqual(outcome.stagedProposalIds, [proposals.first?.id])

        // Approving it creates the group with all three accessories'
        // primary (only) services.
        let approved = try await store.approve(id: proposals[0].id)
        XCTAssertEqual(approved.state, .executed)
        let graph = await service.graph
        XCTAssertEqual(graph.homes.first?.serviceGroups.first?.services.map(\.id),
                       ["acc-lr-1-svc", "acc-lr-2-svc", "acc-lr-3-svc"])
    }

    // MARK: - One create per kind

    func testCreateRoutesOneProposalPerKind() async throws {
        let (agent, store, dispatcher) = makeAgent()

        let outcome = try await run(
            agent,
            turns: [
                .call("create", "{\"kind\": \"room\", \"homeId\": \"home-1\", \"name\": \"Sunroom\"}"),
                .call("create", "{\"kind\": \"zone\", \"homeId\": \"home-1\", \"name\": \"Second Floor\"}"),
                .call("create", """
                {"kind": "timer", "homeId": "home-1", "name": "Sunrise",
                 "fireDate": "2026-11-11T07:30:00Z"}
                """),
                .call("create", """
                {"kind": "event", "homeId": "home-1", "name": "Motion Light",
                 "events": [{"accessoryId": "acc-office-1", "characteristic": "On"}]}
                """),
                .done("I staged four proposals: a room, a zone, and two (disabled) automations."),
            ],
            request: "Set up a Sunroom, a Second Floor zone, a 7:30 automation called Sunrise, and one that turns the fan on."
        )

        let proposals = await store.allProposals()
        XCTAssertEqual(proposals.map(\.tool),
                       ["create_room", "create_zone", "create_timer_trigger", "create_event_trigger"])
        XCTAssertEqual(outcome.stagedProposalIds, proposals.map(\.id))
        XCTAssertEqual(await dispatcher.stagedProposalIds.count, 4)
    }

    // MARK: - Declarative updates replace the complete list

    func testDeclarativeUpdatesStageCompleteListReplacements() async throws {
        let (agent, store, _) = makeAgent()

        let outcome = try await run(
            agent,
            turns: [
                .call("update", "{\"entityId\": \"sg-lamps\", \"members\": [\"acc-lr-1\", \"acc-lr-2\"]}"),
                .call("update", "{\"entityId\": \"zone-upstairs\", \"rooms\": [\"room-living\", \"room-kitchen\"]}"),
                .call("update", """
                {"entityId": "scene-morning", "actions": [
                    {"accessoryId": "acc-lr-1", "characteristic": "Brightness", "value": 40}
                ]}
                """),
                .done("I staged three proposals: the group's members, the zone's rooms, and the scene's actions — each a complete replacement."),
            ],
            request: "Move Desk Lamps to the two living-room lamps, put Kitchen and Living Room in Upstairs, and retune Good Morning to 40%."
        )

        let proposals = await store.allProposals()
        XCTAssertEqual(proposals.map(\.tool),
                       ["set_service_group_members", "set_zone_rooms", "set_scene_actions"])
        XCTAssertEqual(outcome.stagedProposalIds, proposals.map(\.id))
    }

    // MARK: - Infinite-loop model hits the budget

    func testInfiniteLoopModelHitsBudgetAndEndsWithHonestReport() async throws {
        let (agent, store, dispatcher) = makeAgent(budget: 12)

        // Twenty tool-call turns and a final honest report: the budget cuts
        // the loop at 12, and the turns after that see in-band exhaustion.
        var turns: [ScriptedTurn] = (0..<20).map { _ in .call("search", "{\"query\": \"lamp\"}") }
        let honestReport = "I could not finish: my tool budget ran out after 12 calls, so I stopped. I staged no proposals."
        turns.append(.done(honestReport))

        let outcome = try await run(agent, turns: turns, request: "Tidy up my home.")

        // The loop ended with the honest report, and nothing was thrown.
        XCTAssertEqual(outcome.summary, honestReport)

        let attempted = await dispatcher.attemptedCalls
        XCTAssertEqual(attempted.count, 21, "12 executed + 9 refused after budget")
        XCTAssertEqual(attempted.prefix(12).count, 12)
        XCTAssertTrue(attempted.prefix(12).allSatisfy { !$0.wasBudgetExhausted && !$0.isError })
        XCTAssertTrue(attempted.suffix(9).allSatisfy { $0.wasBudgetExhausted })
        let exhaustions = await dispatcher.budgetExhaustions
        XCTAssertEqual(exhaustions, 9)

        let staged = await dispatcher.stagedProposalIds
        XCTAssertTrue(staged.isEmpty, "a read-only loop stages nothing")
        let proposals = await store.allProposals()
        XCTAssertTrue(proposals.isEmpty)
    }

    // MARK: - Vague destructive request stages nothing

    func testVagueDestructiveRequestStagesZeroProposals() async throws {
        let (agent, store, dispatcher) = makeAgent()

        let outcome = try await run(
            agent,
            turns: [
                .call("get_details", "{}"),
                .done("Which rooms do you mean by \u{201C}some\u{201D}? I won\u{2019}t stage anything destructive without specific rooms \u{2014} tell me which ones and I\u{2019}ll stage it for review."),
            ],
            request: "Clean up some of these rooms."
        )

        XCTAssertEqual(outcome.stagedProposalIds, [])
        let staged = await dispatcher.stagedProposalIds
        XCTAssertTrue(staged.isEmpty)
        let proposals = await store.allProposals()
        XCTAssertTrue(proposals.isEmpty)

        // The budget went to reads only; nothing errored.
        let attempted = await dispatcher.attemptedCalls
        XCTAssertEqual(attempted.map(\.tool), ["get_details"])
        XCTAssertFalse(attempted.contains { $0.isError })
    }

    // MARK: - Disambiguation: scene and accessory share a name

    func testSharedNameAsksWhichOneBeforeStaging() async throws {
        var graph = AgentFixtures.graph()
        graph.homes[0].scenes.append(HomeGraph.Scene(
            id: "scene-chill", name: "Chill", type: "AppleScene", actions: []
        ))
        graph.homes[0].rooms[0].accessories.append(
            AgentFixtures.dimmableLight(id: "acc-chill", name: "Chill Light")
        )
        let (agent, store, dispatcher) = makeAgent(graph: graph)

        let outcome = try await run(
            agent,
            turns: [
                .call("search", "{\"query\": \"chill\"}"),
                .done("I found two \u{201C}chill\u{201D} objects \u{2014} a scene and an accessory. Which one should I rename?"),
            ],
            request: "Rename chill to chillax."
        )

        XCTAssertEqual(outcome.stagedProposalIds, [])
        XCTAssertTrue(await dispatcher.stagedProposalIds.isEmpty)
        XCTAssertTrue(await store.allProposals().isEmpty)
        let attempted = await dispatcher.attemptedCalls
        XCTAssertEqual(attempted.map(\.tool), ["search"])
        XCTAssertFalse(attempted.contains { $0.isError })
        XCTAssertTrue(outcome.summary.lowercased().contains("which one"))
    }

    // MARK: - Syracuse-shaped fixture: summary and deep read

    func testLeanSummaryAndDeepReadOnSyracuseShapedHome() async throws {
        let (agent, store, dispatcher) = makeAgent(graph: AgentFixtures.syracuseShapedGraph())

        // No arguments: the lean whole-home summary.
        _ = try await run(
            agent,
            turns: [
                .call("get_details", "{}"),
                .done("Syracuse House: 11 rooms, 71 accessories, 6 scenes, 20 groups, 31 triggers."),
            ],
            request: "Give me a quick overview of my home."
        )
        var attempted = await dispatcher.attemptedCalls
        XCTAssertEqual(attempted.map(\.tool), ["get_details"])
        XCTAssertFalse(attempted.contains { $0.isError })
        XCTAssertTrue(await store.allProposals().isEmpty)

        // A fresh run: kind + id deep read of one accessory.
        let (agent2, store2, dispatcher2) = makeAgent(graph: AgentFixtures.syracuseShapedGraph())
        _ = try await run(
            agent2,
            turns: [
                .call("get_details", "{\"kind\": \"accessory\", \"id\": \"acc-0\"}"),
                .done("Accessory 0: four services, On/Hue/Saturation characteristics."),
            ],
            request: "What can Accessory 0 do?"
        )
        attempted = await dispatcher2.attemptedCalls
        XCTAssertEqual(attempted.map(\.tool), ["get_details"])
        XCTAssertFalse(attempted.contains { $0.isError })
        XCTAssertTrue(await store2.allProposals().isEmpty)
    }
}
#endif
