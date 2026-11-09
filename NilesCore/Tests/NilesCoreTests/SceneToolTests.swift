import Foundation
import MCP
import Testing
@testable import NilesCore

/// The scene-management tools end to end over the fake service: rename,
/// delete (with the linked-trigger offer), and execute (device-immediate) —
/// staging, the deny path that leaves the scene untouched, and the expiry
/// path that applies nothing. No test touches `HMHomeManager`.
@Suite struct SceneToolTests {
    private let t0 = Date(timeIntervalSince1970: 1_762_592_000)

    private func fixtureGraph() -> HomeGraph {
        let kitchen = HomeGraph.Room(
            id: "room-kitchen", name: "Kitchen",
            accessories: [HomeGraph.Accessory(id: "acc-light-a", name: "Light A")]
        )
        let movieNight = HomeGraph.Scene(
            id: "scene-movie", name: "Movie Night", type: "AppleScene",
            actions: [
                HomeGraph.SceneAction(
                    accessoryId: "acc-light-a", accessoryName: "Light A",
                    service: nil, characteristic: "On", characteristicName: nil,
                    valueDescription: "1"
                ),
                HomeGraph.SceneAction(
                    accessoryId: "acc-light-a", accessoryName: "Light A",
                    service: nil, characteristic: "Brightness", characteristicName: nil,
                    valueDescription: "30"
                ),
            ]
        )
        let empty = HomeGraph.Scene(id: "scene-empty", name: "Empty Scene", type: "AppleScene")
        let sunset = HomeGraph.Trigger(
            id: "trigger-sunset", name: "Sunset lights", isEnabled: false,
            linkedSceneIds: ["scene-movie"],
            detail: .timer(fireDate: Date(timeIntervalSince1970: 1_762_592_400), recurrence: [:])
        )
        let independent = HomeGraph.Trigger(
            id: "trigger-other", name: "Unrelated", isEnabled: false,
            detail: .timer(fireDate: Date(timeIntervalSince1970: 1_762_592_400), recurrence: [:])
        )
        let home = HomeGraph.Home(
            id: "home-1",
            name: "Townhouse",
            rooms: [kitchen],
            scenes: [movieNight, empty],
            triggers: [sunset, independent]
        )
        return HomeGraph(homes: [home])
    }

    /// Controllable clock for the store's TTL — expiry is lazy, so tests move
    /// the clock instead of sleeping (same pattern as ProposalPipelineTests).
    private final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: Date
        init(_ time: Date) { self.time = time }
        func advance(by interval: TimeInterval) {
            lock.lock()
            defer { lock.unlock() }
            time = time.addingTimeInterval(interval)
        }
        var now: @Sendable () -> Date { { [self] in self.read() } }
        private func read() -> Date {
            lock.lock()
            defer { lock.unlock() }
            return time
        }
    }

    private func makeContext(
        graph: HomeGraph? = nil, lifetime: TimeInterval = 24 * 60 * 60
    ) -> (fake: FakeHomeKitService, store: ProposalStore, registry: WriteToolRegistry, clock: TestClock) {
        let clock = TestClock(t0)
        let fake = FakeHomeKitService(graph: graph ?? fixtureGraph())
        let store = ProposalStore(homeKit: fake, now: clock.now, lifetime: lifetime)
        let registry = WriteToolRegistry(store: store)
        return (fake, store, registry, clock)
    }

    /// Decodes a successful write-tool result's structured content into the
    /// proposal envelope the agent polls.
    private func proposal(from result: CallTool.Result, sourceLocation: SourceLocation = #_sourceLocation) throws -> Proposal {
        #expect(result.isError != true, sourceLocation: sourceLocation)
        let value = try #require(result.structuredContent, sourceLocation: sourceLocation)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Proposal.self, from: JSONEncoder().encode(value))
    }

    private func errorText(of result: CallTool.Result) -> String? {
        guard result.isError == true else { return nil }
        for case let .text(text, _, _) in result.content {
            return text
        }
        return nil
    }

    // MARK: - Rename

    @Test func renameSceneStagesAndExecutesWithReadBack() async throws {
        let (fake, store, registry, _) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "rename_scene",
            arguments: ["sceneId": .string("scene-movie"), "name": .string("Film Evening")]
        ))
        #expect(staged.state == .staged)
        #expect(staged.entries.first?.op == .rename)
        #expect(staged.card.contains { $0.text.contains("Movie Night") && $0.text.contains("Film Evening") })

        let approved = try await store.approve(id: staged.id)
        #expect(approved.state == .executed)
        #expect(approved.error == nil)

        let graph = await fake.graph
        #expect(graph.homes.first!.scenes.first { $0.id == "scene-movie" }?.name == "Film Evening")
        #expect(approved.evidence.first?.confirmed == true)
        #expect(approved.evidence.first?.claim.contains("Film Evening") == true)
    }

    @Test func renameSceneToAnExistingNameIsRejectedBeforeStaging() async throws {
        var seeded = fixtureGraph()
        seeded.homes[0].scenes.append(HomeGraph.Scene(id: "scene-chill", name: "Chill"))
        let (fake, _, registry, _) = makeContext(graph: seeded)

        let result = await registry.call(
            name: "rename_scene",
            arguments: ["sceneId": .string("scene-movie"), "name": .string("chill")]
        )
        #expect(result.isError == true)
        #expect(errorText(of: result)?.contains("already exists") == true)
        let graph = await fake.graph
        #expect(graph.homes.first!.scenes.first { $0.id == "scene-movie" }?.name == "Movie Night")
    }

    // MARK: - Delete with the linked-trigger offer

    @Test func deleteSceneCardListsActionsAndLinkedTriggersAndKeepsThemByDefault() async throws {
        let (fake, store, registry, _) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "delete_scene",
            arguments: ["sceneId": .string("scene-movie")]
        ))
        #expect(staged.isDestructive == true)
        // The card lists the scene's current actions…
        #expect(staged.card.contains { $0.text.contains("Light A: On → 1") })
        #expect(staged.card.contains { $0.text.contains("Light A: Brightness → 30") })
        // …and every trigger that links it, with the keep path spelled out.
        #expect(staged.card.contains {
            $0.kind == .note && $0.text.contains("Sunset lights") && $0.text.contains("deleteLinkedTriggers")
        })
        // One operation only — the trigger stays.
        #expect(staged.entries.count == 1)

        let approved = try await store.approve(id: staged.id)
        #expect(approved.state == .executed)
        #expect(approved.error == nil)
        #expect(approved.evidence.first?.confirmed == true)

        let graph = await fake.graph
        #expect(graph.homes.first!.scenes.contains { $0.id == "scene-movie" } == false)
        // The kept trigger survives, detached from the deleted scene.
        let kept = graph.homes.first!.triggers.first { $0.id == "trigger-sunset" }
        #expect(kept != nil)
        #expect(kept?.linkedSceneIds.contains("scene-movie") == false)
    }

    @Test func deleteSceneWithDeleteLinkedTriggersDeletesThemToo() async throws {
        let (fake, store, registry, _) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "delete_scene",
            arguments: ["sceneId": .string("scene-movie"), "deleteLinkedTriggers": .bool(true)]
        ))
        #expect(staged.card.contains { $0.kind == .remove && $0.text.contains("Sunset lights") })
        #expect(staged.entries.count == 2)

        let approved = try await store.approve(id: staged.id)
        #expect(approved.state == .executed)

        let graph = await fake.graph
        #expect(graph.homes.first!.scenes.contains { $0.id == "scene-movie" } == false)
        #expect(graph.homes.first!.triggers.contains { $0.id == "trigger-sunset" } == false)
        // The unrelated trigger is untouched.
        #expect(graph.homes.first!.triggers.contains { $0.id == "trigger-other" } == true)
    }

    @Test func denyLeavesSceneAndTriggersUntouched() async throws {
        let (fake, store, registry, _) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "delete_scene",
            arguments: ["sceneId": .string("scene-movie"), "deleteLinkedTriggers": .bool(true)]
        ))
        let denied = try await store.deny(id: staged.id)
        #expect(denied.state == .denied)
        #expect(denied.evidence.isEmpty)

        let graph = await fake.graph
        #expect(graph.homes.first!.scenes.contains { $0.id == "scene-movie" } == true)
        #expect(graph.homes.first!.triggers.contains { $0.id == "trigger-sunset" } == true)
    }

    @Test func expiredDeleteSceneExecutesNothing() async throws {
        let (fake, store, registry, clock) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "delete_scene",
            arguments: ["sceneId": .string("scene-movie")]
        ))

        // Past the 24-hour TTL the lazy sweep retires the proposal: the
        // decision path refuses it and the fake home never saw the change.
        clock.advance(by: 24 * 60 * 60 + 1)

        let listed = await store.allProposals()
        #expect(listed.first?.state == .expired)

        await #expect(throws: ProposalStoreError.proposalNotPending(id: staged.id, state: .expired)) {
            try await store.approve(id: staged.id)
        }

        let graph = await fake.graph
        #expect(graph == fixtureGraph())
    }

    // MARK: - Execute (device-immediate)

    @Test func executeSceneStagesADeviceImmediateCardAndRunsOnApproval() async throws {
        let (fake, store, registry, _) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "execute_scene",
            arguments: ["sceneId": .string("scene-movie")]
        ))
        #expect(staged.state == .staged)
        #expect(staged.card.contains { $0.kind == .note && $0.text.contains("Device-immediate") })
        // The card previews exactly what will apply, per action.
        #expect(staged.card.contains { $0.text.contains("Light A: On → 1") })
        #expect(staged.card.contains { $0.text.contains("Light A: Brightness → 30") })

        let approved = try await store.approve(id: staged.id)
        #expect(approved.state == .executed)
        #expect(approved.error == nil)
        #expect(approved.evidence.first?.confirmed == true)

        let graph = await fake.graph
        // The scene survives its run; there is no graph-observable execution
        // signature until lastExecutionDate lands (read-depth group).
        #expect(graph.homes.first!.scenes.contains { $0.id == "scene-movie" } == true)
    }

    @Test func executeSceneOnAnEmptySceneIsRejectedBeforeStaging() async throws {
        let (fake, _, registry, _) = makeContext()

        let result = await registry.call(
            name: "execute_scene",
            arguments: ["sceneId": .string("scene-empty")]
        )
        #expect(result.isError == true)
        let text = try #require(errorText(of: result))
        #expect(text.contains("Empty Scene"))
        #expect(text.contains("no actions"))
        #expect(text.contains("Nothing was staged"))
        let graph = await fake.graph
        #expect(graph.homes.first!.scenes.contains { $0.id == "scene-empty" } == true)
    }

    @Test func deleteSceneWithUnknownSceneIdIsRejectedBeforeStaging() async throws {
        let (_, _, registry, _) = makeContext()
        let result = await registry.call(
            name: "delete_scene",
            arguments: ["sceneId": .string("scene-x")]
        )
        #expect(result.isError == true)
        #expect(errorText(of: result)?.contains("get_scenes") == true)
    }
}
