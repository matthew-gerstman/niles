import Foundation
import XCTest
#if canImport(FoundationModels)
import FoundationModels
@testable import NilesCore

/// Service-level scripted-model runs: the composition (`AgentService`) over
/// the same production agent core the Siri intent will call. Same scripted
/// model as the runner tests, different seam — the service owns per-request
/// dispatchers and the usage record the Settings surface shows.
@available(iOS 27.0, *)
final class AgentServiceTests: XCTestCase {

    private func makeService() -> (service: AgentService, store: ProposalStore) {
        let fixture = AgentFixtures.registries()
        let service = AgentService(store: fixture.store)
        return (service, fixture.store)
    }

    private func model(_ turns: [ScriptedTurn]) -> ScriptedLanguageModel {
        ScriptedLanguageModel(configuration: ScriptedExecutorConfiguration(turns: turns))
    }

    private let livingRoomScene = """
    {"kind": "scene", "homeId": "home-1", "name": "Living Room 30", "actions": [
        {"accessoryId": "acc-lr-1", "characteristic": "Brightness", "value": 30},
        {"accessoryId": "acc-lr-2", "characteristic": "Brightness", "value": 30},
        {"accessoryId": "acc-lr-3", "characteristic": "Brightness", "value": 30}
    ]}
    """

    // MARK: - One request end to end

    func testRunStagesProposalAndRecordsUsage() async throws {
        let (service, store) = makeService()

        let result = try await service.run(
            "Set the living room lights to 30%.",
            using: model([
                .call("get_details", "{}"),
                .call("create", livingRoomScene),
                .done("Staged 1 proposal for review in Niles: Living Room 30."),
            ])
        )

        // Same proposal the queue would show — staged through the same
        // store MCP clients stage into, never executed.
        let proposals = await store.allProposals()
        XCTAssertEqual(proposals.count, 1)
        XCTAssertEqual(result.stagedProposalIds, [proposals.first?.id ?? "missing"])
        XCTAssertEqual(result.summary, "Staged 1 proposal for review in Niles: Living Room 30.")

        let usage = await service.usage
        XCTAssertEqual(usage.requestCount, 1)
        XCTAssertEqual(usage.toolCallCount, 2, "get_details + create")
        XCTAssertEqual(usage.lastStagedProposalIds, result.stagedProposalIds)
        XCTAssertNotNil(usage.lastRunAt)
    }

    // MARK: - Session per request

    func testSecondRequestStartsAFreshSessionAndReplacesLastStaged() async throws {
        let (service, _) = makeService()

        _ = try await service.run(
            "Set the living room lights to 30%.",
            using: model([
                .call("get_details", "{}"),
                .call("create", livingRoomScene),
                .done("Staged 1 proposal."),
            ])
        )

        // A read-only request: a fresh session — the previous request's
        // tool calls and staged ids do not leak into it.
        let readback = try await service.run(
            "What rooms do I have?",
            using: model([
                .call("search", #"{"query": "room"}"#),
                .done("You have three rooms."),
            ])
        )

        XCTAssertTrue(readback.stagedProposalIds.isEmpty, "a read-only run stages nothing")
        let usage = await service.usage
        XCTAssertEqual(usage.requestCount, 2)
        XCTAssertEqual(usage.toolCallCount, 3, "per-request sessions accumulate into usage, one call each")
        XCTAssertTrue(usage.lastStagedProposalIds.isEmpty, "usage reports the latest request, not a running total of staged ids")
    }

    // MARK: - Per-run availability recheck

    func testPerRunRecheckRefusesWithTheTypedReasonWhenTheGateNoLongerPasses() async throws {
        let fixture = AgentFixtures.registries()
        let counter = EvaluationCounter()
        let service = AgentService(store: fixture.store, availability: {
            counter.increment()
            return .unavailable(.modelNotReady)
        })

        do {
            _ = try await service.run("Set the living room lights to 30%.")
            XCTFail("a stale gate must refuse the run with the typed reason")
        } catch let error as AgentRunError {
            XCTAssertEqual(error, .unavailable(.modelNotReady))
        }

        // The run never reached the model — usage stays at zero.
        let usage = await service.usage
        XCTAssertEqual(usage.requestCount, 0)
        XCTAssertEqual(counter.value, 1, "the recheck runs once per run, not once per service")
    }

    func testPerRunRecheckReevaluatesOnEveryRun() async throws {
        let fixture = AgentFixtures.registries()
        let counter = EvaluationCounter()
        let service = AgentService(store: fixture.store, availability: {
            counter.increment()
            return .unavailable(.modelNotReady)
        })

        for _ in 0..<2 {
            do {
                _ = try await service.run("Set the living room lights to 30%.")
                XCTFail("a stale gate must refuse the run with the typed reason")
            } catch let error as AgentRunError {
                XCTAssertEqual(error, .unavailable(.modelNotReady))
            }
        }
        XCTAssertEqual(counter.value, 2, "each run re-evaluates the gate — the entry-time verdict is never cached")
    }
}

/// A thread-safe evaluation counter for injected availability closures —
/// the actor calls the closure; the test reads the count back.
private final class EvaluationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
#endif
