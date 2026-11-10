import Foundation
import MCP
import Testing
@testable import NilesCore

/// The dispatcher's contract: proxy output byte-identical to direct registry
/// results, a mechanical in-band call budget, response truncation, and
/// staged-proposal bookkeeping. No Foundation Models involved — these run
/// anywhere NilesCore tests run.
@Suite struct AgentDispatcherTests {
    private func text(of result: CallTool.Result) -> String {
        result.content.compactMap { part in
            if case .text(let text) = part { return text.text }
            return nil
        }.joined(separator: "\n")
    }

    // MARK: - Parity: proxy == direct registry call

    @Test func validReadCallIsByteIdenticalToDirectRegistry() async throws {
        let fixture = AgentFixtures.registries()
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes)

        let direct = await fixture.reads.call(name: "get_homes", arguments: [:])
        let proxied = await dispatcher.call(name: "get_homes", arguments: [:])

        #expect(proxied.text == text(of: direct))
        #expect(proxied.isError == (direct.isError == true))
        #expect(proxied.stagedProposalId == nil)
    }

    @Test func validWriteCallIsByteIdenticalToDirectRegistry() async throws {
        let fixture = AgentFixtures.registries()
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes)

        let arguments: [String: MCP.Value] = [
            "homeId": .string("home-1"),
            "name": .string("Movie Time"),
            "actions": .array([.object([
                "accessoryId": .string("acc-lr-1"),
                "characteristic": .string("Brightness"),
                "value": .double(30),
            ])]),
        ]
        let direct = await fixture.writes.call(name: "create_scene", arguments: arguments)
        #expect(direct.isError != true)  // sanity: the fixture stages cleanly

        let fresh = AgentFixtures.registries()
        let secondDispatcher = NilesToolDispatcher(reads: fresh.reads, writes: fresh.writes)
        let proxied = await secondDispatcher.call(name: "create_scene", arguments: arguments)

        #expect(proxied.text == text(of: direct))
        #expect(proxied.isError == (direct.isError == true))
    }

    @Test func invalidArgumentsCallIsByteIdenticalToDirectRegistry() async throws {
        let fixture = AgentFixtures.registries()
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes)

        // create_scene without its required arguments.
        let direct = await fixture.writes.call(name: "create_scene", arguments: [:])
        #expect(direct.isError == true)

        let fresh = AgentFixtures.registries()
        let secondDispatcher = NilesToolDispatcher(reads: fresh.reads, writes: fresh.writes)
        let proxied = await secondDispatcher.call(name: "create_scene", arguments: [:])

        #expect(proxied.text == text(of: direct))
        #expect(proxied.isError)
    }

    @Test func unknownToolCallIsByteIdenticalToDirectWriteRegistry() async throws {
        let fixture = AgentFixtures.registries()
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes)

        let direct = await fixture.writes.call(name: "not_a_tool", arguments: nil)
        #expect(direct.isError == true)

        let fresh = AgentFixtures.registries()
        let secondDispatcher = NilesToolDispatcher(reads: fresh.reads, writes: fresh.writes)
        let proxied = await secondDispatcher.call(name: "not_a_tool", arguments: nil)

        #expect(proxied.text == text(of: direct))
        #expect(proxied.isError)
    }

    @Test func plannerRejectionIsByteIdenticalToDirectRegistry() async throws {
        let fixture = AgentFixtures.registries()
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes)

        // A duplicate room name is rejected by the planner.
        let direct = await fixture.writes.call(name: "create_room", arguments: [
            "homeId": .string("home-1"),
            "name": .string("Living Room"),
        ])
        #expect(direct.isError == true)

        let fresh = AgentFixtures.registries()
        let secondDispatcher = NilesToolDispatcher(reads: fresh.reads, writes: fresh.writes)
        let proxied = await secondDispatcher.call(name: "create_room", arguments: [
            "homeId": .string("home-1"),
            "name": .string("Living Room"),
        ])

        #expect(proxied.text == text(of: direct))
        #expect(proxied.isError)
    }

    // MARK: - Budget

    @Test func budgetExhaustionReturnsInBandErrorAndNeverThrows() async throws {
        let fixture = AgentFixtures.registries()
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes, budget: 3)

        for _ in 0..<3 {
            let outcome = await dispatcher.call(name: "get_homes", arguments: [:])
            #expect(!outcome.isError)
        }
        let fourth = await dispatcher.call(name: "get_homes", arguments: [:])
        #expect(fourth.isError)
        #expect(fourth.text.contains("Budget exhausted"))
        #expect(fourth.text.contains("3"))
        let fifth = await dispatcher.call(name: "get_homes", arguments: [:])
        #expect(fifth.isError)
    }

    @Test func budgetCountsFailedCallsToo() async throws {
        let fixture = AgentFixtures.registries()
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes, budget: 2)

        // Two failing calls still spend the budget: otherwise a model looping
        // on bad arguments spins forever.
        _ = await dispatcher.call(name: "not_a_tool", arguments: nil)
        _ = await dispatcher.call(name: "create_scene", arguments: [:])
        let third = await dispatcher.call(name: "get_homes", arguments: [:])
        #expect(third.isError)
        #expect(third.text.contains("Budget exhausted"))
    }

    // MARK: - Truncation

    @Test func oversizedResponsesAreTruncatedWithMarker() async throws {
        var graph = AgentFixtures.graph()
        // Force a big response: 30 rooms of accessories.
        for index in 0..<30 {
            graph.homes[0].rooms.append(HomeGraph.Room(
                id: "room-x-\(index)", name: "Room \(index)",
                accessories: (0..<12).map { AgentFixtures.dimmableLight(
                    id: "acc-\(index)-\($0)", name: "Light \(index)-\($0)"
                ) }
            ))
        }
        let fixture = AgentFixtures.registries(graph: graph)
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes, responseCharacterLimit: 500)

        let outcome = await dispatcher.call(name: "get_rooms", arguments: ["detail": .string("full")])
        #expect(!outcome.isError)
        #expect(outcome.text.count > 500)
        #expect(outcome.text.count < 500 + 250)  // marker only
        #expect(outcome.text.contains("[truncated by Niles"))
    }

    @Test func smallResponsesAreNotTruncated() async throws {
        let fixture = AgentFixtures.registries()
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes)

        let outcome = await dispatcher.call(name: "get_homes", arguments: [:])
        #expect(!outcome.text.contains("[truncated"))
    }

    // MARK: - Staged-proposal bookkeeping

    @Test func successfulWritesRecordStagedProposalIds() async throws {
        let fixture = AgentFixtures.registries()
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes)

        let outcome = await dispatcher.call(name: "create_room", arguments: [
            "homeId": .string("home-1"),
            "name": "Sunroom",
        ])
        #expect(!outcome.isError)
        #expect(outcome.stagedProposalId != nil)
        let staged = await dispatcher.stagedProposalIds
        #expect(staged.count == 1)
        #expect(staged.first == outcome.stagedProposalId)

        let store = fixture.store
        let proposals = await store.allProposals()
        #expect(proposals.count == 1)
        #expect(proposals.first?.id == outcome.stagedProposalId)
    }

    @Test func failedWritesRecordNothing() async throws {
        let fixture = AgentFixtures.registries()
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes)

        let outcome = await dispatcher.call(name: "create_room", arguments: [
            "homeId": .string("home-1"),
            "name": "Living Room",  // duplicate — planner rejects
        ])
        #expect(outcome.isError)
        #expect(outcome.stagedProposalId == nil)
        let staged = await dispatcher.stagedProposalIds
        #expect(staged.isEmpty)
    }

    @Test func readsAndProposalPollRecordNothing() async throws {
        let fixture = AgentFixtures.registries()
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes)

        _ = await dispatcher.call(name: "get_homes", arguments: [:])
        // get_proposal lives in the write registry but reads state.
        let poll = await dispatcher.call(name: "get_proposal", arguments: ["proposalId": .string("nope")])
        #expect(poll.isError)  // nothing staged to poll
        let staged = await dispatcher.stagedProposalIds
        #expect(staged.isEmpty)
    }

    // MARK: - Syracuse sizing (direction 3)

    @Test func syracuseLeanReadFitsWindowButFullDetailIsCapped() async throws {
        // The sizing finding, asserted: a lean get_rooms answer is a small
        // fraction of the 4,096-token window; a full-detail dump of the same
        // home would flood it, so the dispatcher caps it with the marker.
        let fixture = AgentFixtures.registries(graph: AgentFixtures.syracuseShapedGraph())
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes)

        let lean = await dispatcher.call(name: "get_rooms", arguments: [:])
        #expect(!lean.isError)
        #expect(lean.text.count < 16_000)

        let full = await dispatcher.call(name: "get_rooms", arguments: ["detail": .string("full")])
        #expect(!full.isError)
        #expect(full.text.contains("[truncated by Niles"))
    }

    // MARK: - Toolset surface

    @Test func dispatcherExposesEveryRegistryTool() async throws {
        let fixture = AgentFixtures.registries()
        let dispatcher = NilesToolDispatcher(reads: fixture.reads, writes: fixture.writes)

        let definitions = await dispatcher.toolDefinitions
        let names = Set(definitions.map(\.name))
        #expect(names == fixture.reads.toolNames.union(fixture.writes.toolNames))
        #expect(definitions.count == fixture.reads.toolNames.count + fixture.writes.toolNames.count)
    }
}
