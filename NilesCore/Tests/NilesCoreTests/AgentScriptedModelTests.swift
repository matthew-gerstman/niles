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
private struct ScriptedTurn: Hashable, Sendable {
    /// One tool call per turn: name plus arguments as JSON.
    var toolCall: (tool: String, argumentsJSON: String)?
    var finalText: String

    static func call(_ tool: String, _ argumentsJSON: String) -> ScriptedTurn {
        ScriptedTurn(toolCall: (tool, argumentsJSON), finalText: "")
    }
    static func done(_ text: String) -> ScriptedTurn {
        ScriptedTurn(toolCall: nil, finalText: text)
    }
}

private struct ScriptedExecutorConfiguration: Hashable, Sendable {
    var turns: [ScriptedTurn]
}

private struct ScriptedLanguageModel: LanguageModel {
    typealias Executor = ScriptedExecutor
    var configuration: ScriptedExecutorConfiguration

    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.toolCalling])
    }

    var executorConfiguration: ScriptedExecutorConfiguration { configuration }
}

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
        // per scripted turn keeps this indexing exact.
        let completed = request.transcript.entries.filter { entry in
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
        if let call = turn.toolCall {
            await channel.send(.toolCalls(action: .toolCall(
                id: UUID().uuidString,
                name: call.tool,
                action: .appendArguments(call.argumentsJSON, tokenCount: call.argumentsJSON.count / 4)
            )))
        } else {
            await channel.send(.response(action: .appendText(turn.finalText, tokenCount: turn.finalText.count / 4)))
        }
    }
}

final class AgentScriptedModelTests: XCTestCase {
    private func makeAgent(
        budget: Int = NilesToolDispatcher.defaultBudget,
        graph: HomeGraph = AgentFixtures.graph()
    ) -> (agent: NilesAgent, store: ProposalStore, dispatcher: NilesToolDispatcher) {
        let fixture = AgentFixtures.registries(graph: graph)
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes, budget: budget)
        return (NilesAgent(dispatcher: dispatcher), fixture.store, dispatcher)
    }

    private func run(
        _ agent: NilesAgent, turns: [ScriptedTurn], request: String
    ) async throws -> NilesAgent.Outcome {
        let model = ScriptedLanguageModel(configuration: ScriptedExecutorConfiguration(turns: turns))
        return try await agent.run(request, using: model)
    }

    // MARK: - Living-room lights to 30%

    @available(iOS 27.0, *)
    func testLivingRoomLightsTo30PercentStagesOneCreateSceneProposal() async throws {
        let (agent, store, _) = makeAgent()

        let outcome = try await run(
            agent,
            turns: [
                .call("get_rooms", "{}"),
                .call("create_scene", """
                {"homeId": "home-1", "name": "Living Room 30%", "actions": [
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

    // MARK: - Infinite-loop model hits the budget

    @available(iOS 27.0, *)
    func testInfiniteLoopModelHitsBudgetAndEndsWithHonestReport() async throws {
        let (agent, store, dispatcher) = makeAgent(budget: 12)

        // Twenty tool-call turns and a final honest report: the budget cuts
        // the loop at 12, and the turns after that see in-band exhaustion.
        var turns: [ScriptedTurn] = (0..<20).map { _ in .call("get_homes", "{}") }
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

    @available(iOS 27.0, *)
    func testVagueDestructiveRequestStagesZeroProposals() async throws {
        let (agent, store, dispatcher) = makeAgent()

        let outcome = try await run(
            agent,
            turns: [
                .call("get_rooms", "{}"),
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
        XCTAssertEqual(attempted.map(\.tool), ["get_rooms"])
        XCTAssertFalse(attempted.contains { $0.isError })
    }
}
#endif
