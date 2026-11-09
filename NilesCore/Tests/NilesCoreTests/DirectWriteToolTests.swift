import Foundation
import MCP
import Testing
@testable import NilesCore

/// The direct-write tool end to end over the fake service: staging with the
/// device-immediate card, metadata rejection before staging, the deny and
/// expiry paths that leave the device untouched, and approval that writes
/// with read-back evidence. No test touches `HMHomeManager`.
@Suite struct DirectWriteToolTests {
    private let t0 = Date(timeIntervalSince1970: 1_762_592_000)

    private let brightnessUUID = "00000008-0000-1000-8000-0026BB765291"

    /// Lamp B carries a Lightbulb service (On, currently 0; Brightness,
    /// currently 20 with 0…100 metadata) and a Speaker service (Track Name,
    /// no reading). No Metadata has a service with no characteristics — the
    /// capability data is missing, so staging must stay permissive.
    private func fixtureGraph() -> HomeGraph {
        let on = HomeGraph.CharacteristicRef(
            id: "char-on",
            type: "00000025-0000-1000-8000-0026BB765291",
            name: "On",
            valueDescription: "0",
            metadata: HomeGraph.CharacteristicMetadata(format: "bool")
        )
        let brightness = HomeGraph.CharacteristicRef(
            id: "char-brightness",
            type: brightnessUUID,
            name: "Brightness",
            valueDescription: "20",
            metadata: HomeGraph.CharacteristicMetadata(
                format: "int", units: "percentage", minValue: 0, maxValue: 100, step: 1
            )
        )
        let track = HomeGraph.CharacteristicRef(
            id: "char-track",
            type: "000000CB-0000-1000-8000-0026BB765291",
            name: "Track Name",
            valueDescription: nil,
            metadata: HomeGraph.CharacteristicMetadata(format: "string")
        )
        let lightbulb = HomeGraph.AccessoryService(
            id: "svc-light",
            name: "Lightbulb",
            serviceType: "00000043-0000-1000-8000-0026BB765291",
            characteristics: [on, brightness]
        )
        let speaker = HomeGraph.AccessoryService(id: "svc-speaker", name: "Speaker", characteristics: [track])
        let lamp = HomeGraph.Accessory(id: "acc-lamp", name: "Lamp B", services: [lightbulb, speaker])
        let bare = HomeGraph.Accessory(
            id: "acc-empty",
            name: "No Metadata",
            services: [HomeGraph.AccessoryService(id: "svc-empty", name: "Empty", characteristics: [])]
        )
        let home = HomeGraph.Home(
            id: "home-1",
            name: "Townhouse",
            rooms: [HomeGraph.Room(id: "room-kitchen", name: "Kitchen", accessories: [lamp, bare])]
        )
        return HomeGraph(homes: [home])
    }

    /// Controllable clock for the store's TTL — expiry is lazy, so tests move
    /// the clock instead of sleeping (same pattern as SceneToolTests).
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

    // MARK: - Staging

    @Test func writeCharacteristicStagesADeviceImmediateCardAndRunsOnApproval() async throws {
        let (fake, store, registry, _) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "write_characteristic",
            arguments: ["accessoryId": .string("acc-lamp"), "characteristic": .string("Brightness"), "value": .int(45)]
        ))
        #expect(staged.state == .staged)
        #expect(staged.title.contains("Set “Lamp B” Brightness to 45"))
        // The card shows current → target, the accessory name, and the
        // device-immediate severity note.
        #expect(staged.card.contains { $0.kind == .plain && $0.text.contains("Lamp B: Brightness 20 → 45") })
        #expect(staged.card.contains { $0.kind == .note && $0.text.contains("Device-immediate") })
        // One update diff entry carrying the before and after readings.
        #expect(staged.entries.count == 1)
        #expect(staged.entries[0].op == .update)
        #expect(staged.entries[0].before == "20")
        #expect(staged.entries[0].after == "45")

        let approved = try await store.approve(id: staged.id)
        #expect(approved.state == .executed)
        #expect(approved.error == nil)

        let graph = await fake.graph
        let written = graph.homes[0].rooms[0].accessories[0].services[0].characteristics[1]
        #expect(written.name == "Brightness")
        #expect(written.valueDescription == "45")
        // Read-back evidence confirms the post-write reading.
        #expect(approved.evidence.count == 1)
        #expect(approved.evidence.first?.confirmed == true)
        #expect(approved.evidence.first?.claim.contains("45") == true)
    }

    @Test func writeCharacteristicResolvesTheUUIDSpelling() async throws {
        let (fake, store, registry, _) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "write_characteristic",
            arguments: ["accessoryId": .string("acc-lamp"), "characteristic": .string(brightnessUUID), "value": .int(45)]
        ))
        #expect(staged.state == .staged)
        #expect(staged.card.contains { $0.text.contains("Lamp B: Brightness 20 → 45") })

        let approved = try await store.approve(id: staged.id)
        #expect(approved.state == .executed)
        #expect(approved.error == nil)
        let graph = await fake.graph
        #expect(graph.homes[0].rooms[0].accessories[0].services[0].characteristics[1].valueDescription == "45")
    }

    @Test func writeCharacteristicTargetsTheNamedServiceWhenGiven() async throws {
        let (fake, store, registry, _) = makeContext()

        // Both services of Lamp B are candidates without a filter; the
        // Speaker service pins the target to its Track Name characteristic.
        let staged = try proposal(from: await registry.call(
            name: "write_characteristic",
            arguments: [
                "accessoryId": .string("acc-lamp"),
                "service": .string("Speaker"),
                "characteristic": .string("Track Name"),
                "value": .string("Radiohead"),
            ]
        ))
        #expect(staged.state == .staged)

        let approved = try await store.approve(id: staged.id)
        #expect(approved.state == .executed)
        let graph = await fake.graph
        #expect(graph.homes[0].rooms[0].accessories[0].services[1].characteristics[0].valueDescription == "Radiohead")
    }

    // MARK: - Staging rejections (typed, before a card exists)

    @Test func writeCharacteristicNamesTheCharacteristicAndCurrentReadingWhenOutOfRange() async throws {
        let (fake, _, registry, _) = makeContext()

        let result = await registry.call(
            name: "write_characteristic",
            arguments: ["accessoryId": .string("acc-lamp"), "characteristic": .string("Brightness"), "value": .int(150)]
        )
        #expect(result.isError == true)
        let text = try #require(errorText(of: result))
        #expect(text.contains("Brightness"))
        #expect(text.contains("currently reads 20"))
        #expect(text.contains("0…100"))
        #expect(text.contains("Nothing was staged"))

        let graph = await fake.graph
        #expect(graph.homes[0].rooms[0].accessories[0].services[0].characteristics[1].valueDescription == "20")
    }

    @Test func writeCharacteristicRejectsAStringOnANumberCharacteristic() async throws {
        let (fake, _, registry, _) = makeContext()

        let result = await registry.call(
            name: "write_characteristic",
            arguments: ["accessoryId": .string("acc-lamp"), "characteristic": .string("Brightness"), "value": .string("bright")]
        )
        #expect(result.isError == true)
        let text = try #require(errorText(of: result))
        #expect(text.contains("holds numbers"))
        #expect(text.contains("currently reads 20"))
        #expect(text.contains("Nothing was staged"))

        let graph = await fake.graph
        #expect(graph.homes[0].rooms[0].accessories[0].services[0].characteristics[1].valueDescription == "20")
    }

    @Test func writeCharacteristicToTheCurrentValueIsRejectedAsNoOp() async throws {
        let (_, _, registry, _) = makeContext()

        let result = await registry.call(
            name: "write_characteristic",
            arguments: ["accessoryId": .string("acc-lamp"), "characteristic": .string("Brightness"), "value": .int(20)]
        )
        #expect(result.isError == true)
        let text = try #require(errorText(of: result))
        #expect(text.contains("Nothing to change"))
        #expect(text.contains("already reads 20"))
    }

    @Test func writeCharacteristicOnAnUnknownAccessoryIsRejectedBeforeStaging() async throws {
        let (_, _, registry, _) = makeContext()

        let result = await registry.call(
            name: "write_characteristic",
            arguments: ["accessoryId": .string("acc-x"), "characteristic": .string("Brightness"), "value": .int(30)]
        )
        #expect(result.isError == true)
        let text = try #require(errorText(of: result))
        #expect(text.contains("No accessory"))
        #expect(text.contains("Nothing was staged"))
    }

    @Test func writeCharacteristicWithUnverifiableCapabilityDataStagesPermissively() async throws {
        let (fake, store, registry, _) = makeContext()

        // No Metadata's services carry no characteristics, so capability
        // data is missing — staging stays permissive and says so.
        let staged = try proposal(from: await registry.call(
            name: "write_characteristic",
            arguments: ["accessoryId": .string("acc-empty"), "characteristic": .string("Brightness"), "value": .int(30)]
        ))
        #expect(staged.state == .staged)
        #expect(staged.card.contains { $0.kind == .note && $0.text.contains("Could not verify") })

        // Approval runs; the executor's own check (the fake mirrors
        // HomeKit's rejection) fails the write with a typed error.
        let failed = try await store.approve(id: staged.id)
        #expect(failed.state == .failed)
        #expect(failed.error?.contains("Brightness") == true)
        let graph = await fake.graph
        #expect(graph == fixtureGraph())
    }

    // MARK: - Deny and expiry apply nothing

    @Test func deniedWriteLeavesTheCharacteristicUntouched() async throws {
        let (fake, store, registry, _) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "write_characteristic",
            arguments: ["accessoryId": .string("acc-lamp"), "characteristic": .string("Brightness"), "value": .int(45)]
        ))
        let denied = try await store.deny(id: staged.id)
        #expect(denied.state == .denied)
        #expect(denied.evidence.isEmpty)

        let graph = await fake.graph
        #expect(graph == fixtureGraph())
    }

    @Test func expiredWriteExecutesNothing() async throws {
        let (fake, store, registry, clock) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "write_characteristic",
            arguments: ["accessoryId": .string("acc-lamp"), "characteristic": .string("Brightness"), "value": .int(45)]
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
}
