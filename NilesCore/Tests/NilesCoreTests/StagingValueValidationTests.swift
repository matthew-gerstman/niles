import Foundation
import Testing
@testable import NilesCore

/// Characteristic write values are validated against the target
/// characteristic's declared metadata at staging — the same shared
/// `DeviceWriteResolver.valueViolation` check the executor's resolution
/// runs — so a proposal that passes staging always executes and the Power
/// State '0' failure from the Nov 12 Duo QA run (string '0' staged for a
/// boolean-format characteristic, rejected only when execution reached the
/// typed boundary) is rejected before a human ever sees a card.
///
/// Follows the PR #15 validation-test pattern: pure fixtures over
/// `FakeHomeKitService`, no `HMHomeManager`, planner rejections asserted as
/// typed `PlannerError` messages.
@Suite struct StagingValueValidationTests {

    // MARK: - Fixtures

    /// Power State: bool format, valid values 0/1 — the QA fixture.
    private static let powerState = HomeGraph.CharacteristicRef(
        id: "char-power",
        type: "00000025-0000-1000-8000-0026BB765291",
        name: "Power State",
        valueDescription: "0",
        metadata: HomeGraph.CharacteristicMetadata(
            format: "bool", minValue: 0, maxValue: 1, validValues: [0, 1]
        )
    )

    /// Brightness: int 0…100, step 1.
    private static let brightness = HomeGraph.CharacteristicRef(
        id: "char-brightness",
        type: "00000008-0000-1000-8000-0026BB765291",
        name: "Brightness",
        valueDescription: "0",
        metadata: HomeGraph.CharacteristicMetadata(format: "int", minValue: 0, maxValue: 100, step: 1)
    )

    /// Saturation: float 0…1.
    private static let saturation = HomeGraph.CharacteristicRef(
        id: "char-saturation",
        type: "0000000F-0000-1000-8000-0026BB765291",
        name: "Saturation",
        valueDescription: "0.5",
        metadata: HomeGraph.CharacteristicMetadata(format: "float", minValue: 0, maxValue: 1)
    )

    /// Label: string format — the kind-mismatch fixture.
    private static let label = HomeGraph.CharacteristicRef(
        id: "char-label",
        type: "0000004A-0000-1000-8000-0026BB765291",
        name: "Label",
        valueDescription: "front",
        metadata: HomeGraph.CharacteristicMetadata(format: "string")
    )

    private func fixtureGraph() -> HomeGraph {
        let lampService = HomeGraph.AccessoryService(
            id: "svc-light", name: "Lightbulb", serviceType: "00000043-0000-1000-8000-0026BB765291",
            characteristics: [Self.powerState, Self.brightness, Self.saturation, Self.label]
        )
        let lamp = HomeGraph.Accessory(
            id: "acc-lamp", name: "Lamp B", reachable: true, bridged: false,
            category: "com.apple.hap.lightbulb", services: [lampService]
        )
        let living = HomeGraph.Room(id: "room-living", name: "Living Room", accessories: [lamp])
        let home = HomeGraph.Home(id: "home-1", name: "Townhouse", rooms: [living])
        return HomeGraph(homes: [home])
    }

    private func makeStore() -> (fake: FakeHomeKitService, store: ProposalStore) {
        let fake = FakeHomeKitService(graph: fixtureGraph())
        return (fake, ProposalStore(homeKit: fake))
    }

    /// Runs a staging request expected to fail; returns the planner error,
    /// or records an issue and returns nil when nothing was thrown.
    private func stagingError(
        sourceLocation: SourceLocation = #_sourceLocation, _ body: () throws -> Void
    ) -> ProposalPlanner.PlannerError? {
        do {
            try body()
            Issue.record("expected staging to fail", sourceLocation: sourceLocation)
            return nil
        } catch {
            #expect(error is ProposalPlanner.PlannerError, "\(error)", sourceLocation: sourceLocation)
            return error as? ProposalPlanner.PlannerError
        }
    }

    // MARK: - Valid writes pass staging

    @Test func validBoolWriteStages() throws {
        let plan = try ProposalPlanner.plan(
            .writeCharacteristic(
                accessoryId: "acc-lamp", service: nil, characteristic: "Power State", value: .bool(true)
            ),
            graph: fixtureGraph()
        )
        #expect(plan.tool == "write_characteristic")
    }

    @Test func validIntWriteStagesAndExecutes() async throws {
        let (fake, _) = makeStore()
        let plan = try ProposalPlanner.plan(
            .writeCharacteristic(
                accessoryId: "acc-lamp", service: nil, characteristic: "Brightness", value: .int(30)
            ),
            graph: fixtureGraph()
        )
        guard let operation = plan.operations.first, case .writeCharacteristic(_, let spec) = operation else {
            Issue.record("expected a write operation")
            return
        }
        _ = try await fake.perform(.writeCharacteristic(homeId: "home-1", action: spec))
        let graph = await fake.graph
        let written = graph.homes.first?.rooms.first?.accessories.first?
            .characteristic("Brightness", service: nil)?.valueDescription
        #expect(written == "30")
    }

    @Test func validFloatWriteStages() throws {
        _ = try ProposalPlanner.plan(
            .writeCharacteristic(
                accessoryId: "acc-lamp", service: nil, characteristic: "Saturation", value: .double(0.25)
            ),
            graph: fixtureGraph()
        )
    }

    // MARK: - The widening: numeric strings that conform after conversion

    @Test func numericStringWidensForIntFormat() throws {
        // '30' spelled as a string for a brightness int — accepted.
        _ = try ProposalPlanner.plan(
            .writeCharacteristic(
                accessoryId: "acc-lamp", service: nil, characteristic: "Brightness", value: .string("30")
            ),
            graph: fixtureGraph()
        )
    }

    @Test func numericStringOutOfRangeStillRejected() throws {
        guard case .invalidInput(let message)? = stagingError({
            try ProposalPlanner.plan(
                .writeCharacteristic(
                    accessoryId: "acc-lamp", service: nil, characteristic: "Brightness", value: .string("300")
                ),
                graph: fixtureGraph()
            )
        }) else { return }
        #expect(message.contains("Brightness"))
        #expect(message.contains("300"))
        #expect(message.contains("out of range"))
    }

    // MARK: - The Power State '0' fixture: rejected at staging, named

    @Test func stringZeroOnBooleanIsRejectedAtStaging() throws {
        // The Nov 12 Duo QA fixture: a string '0' for a boolean-format
        // Power State staged fine and failed at execution. Staging now
        // rejects it with an error naming the characteristic, the value,
        // and the violated constraint.
        guard case .invalidInput(let message)? = stagingError({
            try ProposalPlanner.plan(
                .writeCharacteristic(
                    accessoryId: "acc-lamp", service: nil, characteristic: "Power State", value: .string("0")
                ),
                graph: fixtureGraph()
            )
        }) else { return }
        #expect(message.contains("Power State"))
        #expect(message.contains("0"))
        #expect(message.contains("boolean"))
    }

    @Test func nonNumericStringOnNumberKindIsRejected() throws {
        guard case .invalidInput(let message)? = stagingError({
            try ProposalPlanner.plan(
                .writeCharacteristic(
                    accessoryId: "acc-lamp", service: nil, characteristic: "Brightness", value: .string("bright")
                ),
                graph: fixtureGraph()
            )
        }) else { return }
        #expect(message.contains("holds numbers"))
    }

    // MARK: - Constraint coverage: range, step, valid values, wrong type

    @Test func outOfRangeIntFailsStaging() throws {
        guard case .invalidInput(let message)? = stagingError({
            try ProposalPlanner.plan(
                .writeCharacteristic(
                    accessoryId: "acc-lamp", service: nil, characteristic: "Brightness", value: .int(300)
                ),
                graph: fixtureGraph()
            )
        }) else { return }
        #expect(message.contains("out of range"))
    }

    @Test func offStepValueFailsStaging() throws {
        var metadata = Self.brightness.metadata!
        metadata.step = 5
        var graph = fixtureGraph()
        graph.homes[0].rooms[0].accessories[0].services[0].characteristics[1].metadata = metadata
        guard case .invalidInput(let message)? = stagingError({
            try ProposalPlanner.plan(
                .writeCharacteristic(
                    accessoryId: "acc-lamp", service: nil, characteristic: "Brightness", value: .int(31)
                ),
                graph: graph
            )
        }) else { return }
        #expect(message.contains("steps of 5"))
    }

    @Test func wrongTypeForStringKindFailsStaging() throws {
        guard case .invalidInput(let message)? = stagingError({
            try ProposalPlanner.plan(
                .writeCharacteristic(
                    accessoryId: "acc-lamp", service: nil, characteristic: "Label", value: .int(5)
                ),
                graph: fixtureGraph()
            )
        }) else { return }
        #expect(message.contains("holds strings"))
    }

    // MARK: - Scene actions share the same rule

    @Test func sceneActionWithStringZeroFailsStaging() throws {
        guard case .validationFailed(let messages)? = stagingError({
            try ProposalPlanner.createScene(
                homeId: "home-1", name: "Movie Night",
                actions: [
                    SceneActionSpec(
                        accessoryId: "acc-lamp", service: nil, characteristic: "Power State", value: .string("0")
                    )
                ],
                graph: fixtureGraph()
            )
        }) else { return }
        let joined = messages.joined(separator: " ")
        #expect(joined.contains("Power State"))
        #expect(joined.contains("boolean"))
    }

    @Test func validSceneActionStillStages() throws {
        let plan = try ProposalPlanner.createScene(
            homeId: "home-1", name: "Movie Night",
            actions: [
                SceneActionSpec(accessoryId: "acc-lamp", service: nil, characteristic: "Power State", value: .bool(true)),
                SceneActionSpec(accessoryId: "acc-lamp", service: nil, characteristic: "Brightness", value: .string("30")),
            ],
            graph: fixtureGraph()
        )
        #expect(plan.tool == "create_scene")
    }

    @Test func executorResolutionRejectsWhatStagingRejects() throws {
        // The executor half of the shared rule: a scene action that fails
        // staging also fails resolution against the device view — even if
        // it reached execution through a stale path.
        var view = DeviceHomeView()
        view.homes = [
            DeviceHomeView.Home(
                id: "home-1", name: "Townhouse",
                rooms: [DeviceHomeView.Room(id: "room-living", name: "Living Room", accessoryIds: ["acc-lamp"])],
                accessories: [DeviceHomeView.Accessory(
                    id: "acc-lamp", name: "Lamp B", supportsIdentify: true,
                    services: [DeviceHomeView.Service(
                        id: "svc-light", name: "Lightbulb", serviceType: "00000043-0000-1000-8000-0026BB765291",
                        characteristics: [DeviceHomeView.Characteristic(
                            id: "char-power", type: "00000025-0000-1000-8000-0026BB765291",
                            name: "Power State", kind: .number,
                            metadata: HomeGraph.CharacteristicMetadata(format: "bool", validValues: [0, 1])
                        )]
                    )]
                )]
            )
        ]
        #expect(throws: HomeKitWriteError.invalidOperation(
            "Characteristic Power State on “Lamp B” cannot take 0: takes a boolean (true or false), not the string “0”."
        )) {
            try DeviceWriteResolver.resolve(
                .addActionSet(
                    homeId: "home-1", name: "Bad Scene",
                    actions: [SceneActionSpec(
                        accessoryId: "acc-lamp", service: nil, characteristic: "Power State", value: .string("0")
                    )]
                ),
                in: view
            )
        }
    }

    // MARK: - Batch all-or-nothing

    @Test func batchWithOneInvalidValueStagesNothing() async throws {
        let (fake, store) = makeStore()
        do {
            _ = try await store.stageBatch([
                BatchOperation(tool: "write_characteristic", arguments: [
                    "accessoryId": "acc-lamp", "characteristic": "Power State", "value": .bool(true),
                ]),
                BatchOperation(tool: "write_characteristic", arguments: [
                    "accessoryId": "acc-lamp", "characteristic": "Power State", "value": .string("0"),
                ]),
            ])
            Issue.record("expected stageBatch to throw")
        } catch let error as ProposalStoreError {
            guard case .validationFailed(let messages) = error else {
                Issue.record("expected validationFailed, got \(error)")
                return
            }
            let joined = messages.joined(separator: " ")
            #expect(joined.contains("Operation 2"))
            #expect(joined.contains("Power State"))
            #expect(joined.contains("boolean"))
        }
        #expect(await store.allProposals().isEmpty, "the whole batch must stage nothing")
        #expect(await fake.graph.homes[0].rooms[0].accessories[0]
            .characteristic("Power State", service: nil)?.valueDescription == "0",
            "no member of the batch applied")
    }

    // MARK: - Execution: widened strings write as numbers

    @Test func widenedNumericStringExecutesAsNumber() async throws {
        let (fake, _) = makeStore()
        let spec = SceneActionSpec(
            accessoryId: "acc-lamp", service: nil, characteristic: "Brightness", value: .string("30")
        )
        _ = try await fake.perform(.writeCharacteristic(homeId: "home-1", action: spec))
        let graph = await fake.graph
        let written = graph.homes.first?.rooms.first?.accessories.first?
            .characteristic("Brightness", service: nil)?.valueDescription
        #expect(written == "30")
    }

    @Test func executorFakeRejectsStringZeroForBoolean() async throws {
        let (fake, _) = makeStore()
        let spec = SceneActionSpec(
            accessoryId: "acc-lamp", service: nil, characteristic: "Power State", value: .string("0")
        )
        await #expect(throws: HomeKitWriteError.self) {
            try await fake.perform(.writeCharacteristic(homeId: "home-1", action: spec))
        }
    }
}
