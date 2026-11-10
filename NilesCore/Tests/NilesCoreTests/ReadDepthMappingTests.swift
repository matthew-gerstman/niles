import Foundation
import HomeKit
import MCP
import Testing
@testable import NilesCore

/// Read-depth (spec group 3): values, metadata, accessory state, scene
/// execution date, trigger activation, and hub/authorization state.
///
/// The mapping is split so everything with a decision in it is pure over
/// value types — `HMCharacteristicMetadata` has readonly properties and no
/// populated public initializer, so populated metadata enters through the
/// pure core (`characteristicMetadata(format:...)`), and the HM adapter
/// stays a one-liner. No test touches `HMHomeManager`; the async
/// `readValue` shell gets its device QA in the final wave.
@Suite struct ReadDepthMappingTests {
    // MARK: - Metadata mapping (pure core)

    @Test func populatedMetadataMapsEveryField() throws {
        let format = HMCharacteristicMetadataFormatFloat
        let units = HMCharacteristicMetadataUnitsPercentage
        let metadata = try #require(HomeManagerHomeKitService.characteristicMetadata(
            format: format,
            units: units,
            minimum: NSNumber(value: 0),
            maximum: NSNumber(value: 100),
            step: NSNumber(value: 1),
            validValues: nil
        ))
        // Pass-through is asserted against the input parameters, not string
        // literals: the constant values live in the framework binary, not
        // the headers, and the mapping's job is identity, not renaming.
        #expect(metadata.format == format)
        #expect(metadata.units == units)
        #expect(metadata.minValue == 0)
        #expect(metadata.maxValue == 100)
        #expect(metadata.step == 1)
        #expect(metadata.validValues == nil)
    }

    @Test func validValuesMapToIntegerArray() throws {
        let metadata = try #require(HomeManagerHomeKitService.characteristicMetadata(
            format: HMCharacteristicMetadataFormatUInt8,
            units: nil,
            minimum: nil,
            maximum: nil,
            step: nil,
            validValues: [NSNumber(value: 0), NSNumber(value: 1)]
        ))
        #expect(metadata.validValues == [0, 1])
    }

    /// The write path derives `ValueKind` from the declared format string;
    /// the derivation is pinned against the framework constants themselves
    /// (which live in the framework binary, not the headers), so a direct
    /// write's NSNumber/NSString rendering can never drift from what the
    /// read side maps.
    @Test func valueKindDerivationMatchesTheHomeKitFormatConstants() {
        #expect(DeviceHomeView.ValueKind(format: HMCharacteristicMetadataFormatString) == .string)
        #expect(DeviceHomeView.ValueKind(format: HMCharacteristicMetadataFormatBool) == .number)
        #expect(DeviceHomeView.ValueKind(format: HMCharacteristicMetadataFormatInt) == .number)
        #expect(DeviceHomeView.ValueKind(format: HMCharacteristicMetadataFormatFloat) == .number)
        #expect(DeviceHomeView.ValueKind(format: HMCharacteristicMetadataFormatUInt8) == .number)
        #expect(DeviceHomeView.ValueKind(format: HMCharacteristicMetadataFormatUInt16) == .number)
        #expect(DeviceHomeView.ValueKind(format: HMCharacteristicMetadataFormatUInt32) == .number)
        #expect(DeviceHomeView.ValueKind(format: HMCharacteristicMetadataFormatUInt64) == .number)
        #expect(DeviceHomeView.ValueKind(format: nil) == .unknown)
        #expect(DeviceHomeView.ValueKind(format: "something-else") == .unknown)
    }

    @Test func metadataWithoutAnythingMapsToNil() {
        #expect(
            HomeManagerHomeKitService.characteristicMetadata(
                format: nil, units: nil, minimum: nil, maximum: nil, step: nil, validValues: nil
            ) == nil
        )
    }

    // MARK: - Value rendering (the one read-side rule)

    @Test func valuesRenderLikeSceneActionsDo() {
        #expect(HomeManagerHomeKitService.valueDescription(from: NSNumber(value: 30)) == "30")
        #expect(HomeManagerHomeKitService.valueDescription(from: NSNumber(value: true)) == "1")
        #expect(HomeManagerHomeKitService.valueDescription(from: NSNumber(value: 0.5)) == "0.5")
        #expect(HomeManagerHomeKitService.valueDescription(from: "Warm" as NSString) == "Warm")
    }

    @Test func missingValueRendersAsNilNotTheStringNil() {
        #expect(HomeManagerHomeKitService.valueDescription(from: nil) == nil)
    }

    // MARK: - Hub state, authorization, activation state

    @Test func hubStatesRenderJSONFriendlyNames() {
        #expect(HomeManagerHomeKitService.hubStateDescription(.notAvailable) == "notAvailable")
        #expect(HomeManagerHomeKitService.hubStateDescription(.connected) == "connected")
        #expect(HomeManagerHomeKitService.hubStateDescription(.disconnected) == "disconnected")
    }

    @Test func authorizationStatusRendersEverySetBit() {
        #expect(
            HomeManagerHomeKitService.authorizationStatusDescription([]) == "notDetermined"
        )
        #expect(
            HomeManagerHomeKitService.authorizationStatusDescription(.authorized) == "authorized"
        )
        // The mask can combine — restricted AND authorized renders both.
        #expect(
            HomeManagerHomeKitService.authorizationStatusDescription([.restricted, .authorized])
                == "restricted,authorized"
        )
    }

    @Test func activationStatesRenderJSONFriendlyNames() {
        #expect(HomeManagerHomeKitService.activationStateDescription(.disabled) == "disabled")
        #expect(HomeManagerHomeKitService.activationStateDescription(.enabled) == "enabled")
        #expect(
            HomeManagerHomeKitService.activationStateDescription(.disabledNoHomeHub) == "disabledNoHomeHub"
        )
    }

    @Test func activationStateByRawValueIncludingUnknown() {
        #expect(HomeManagerHomeKitService.activationStateDescription(rawValue: 0) == "disabled")
        #expect(HomeManagerHomeKitService.activationStateDescription(rawValue: 4) == "enabled")
        // Unknown raw values (future HomeKit cases) render as the number.
        #expect(HomeManagerHomeKitService.activationStateDescription(rawValue: 9) == "9")
    }

    // MARK: - Applying read values to a graph

    @Test func applyingValuesFillsOnlyTheReadCharacteristics() {
        var graph = makeGraph()
        HomeManagerHomeKitService.applyingValues(
            ["char-kitchen-on": "1", "char-missing": "30"], to: &graph
        )
        let lamp = graph.homes[0].rooms[0].accessories[0]
        let on = lamp.services[0].characteristics.first { $0.id == "char-kitchen-on" }
        let brightness = lamp.services[0].characteristics.first { $0.id == "char-kitchen-brightness" }
        #expect(on?.valueDescription == "1")
        // A failed/absent read leaves the value unknown — nil, not "nil".
        #expect(brightness?.valueDescription == nil)
    }

    // MARK: - Old-graph decode compatibility

    @Test func graphsBeforeReadDepthStillDecode() throws {
        // Hand-written JSON in the pre-read-depth shape.
        let json = """
        {
          "homes": [{
            "id": "home-1",
            "name": "Old Graph",
            "rooms": [{
              "id": "room-1",
              "name": "Living Room",
              "accessories": [{
                "id": "acc-1",
                "name": "Lamp",
                "services": [{
                  "id": "svc-1",
                  "name": "Lamp",
                  "characteristics": [{"id": "char-1", "type": "On"}]
                }]
              }]
            }],
            "scenes": [{"id": "scene-1", "name": "Movie", "actions": []}],
            "triggers": [{
              "id": "trig-1",
              "name": "Evening",
              "isEnabled": false,
              "detail": {"unknown": {"kind": "HMFutureTrigger"}}
            }]
          }]
        }
        """
        let graph = try JSONDecoder().decode(HomeGraph.self, from: Data(json.utf8))
        let accessory = try #require(graph.homes.first?.rooms.first?.accessories.first)
        #expect(accessory.reachable == true)
        #expect(accessory.bridged == false)
        #expect(accessory.category == nil)
        #expect(accessory.firmwareVersion == nil)
        let characteristic = try #require(accessory.services.first?.characteristics.first)
        #expect(characteristic.valueDescription == nil)
        #expect(characteristic.metadata == nil)
        let trigger = try #require(graph.homes.first?.triggers.first)
        #expect(trigger.triggerActivationState == nil)
        #expect(graph.homes.first?.scenes.first?.lastExecutionDate == nil)
        #expect(graph.authorizationStatus == nil)
    }

    // MARK: - Registry round-trips

    @Test func roomsToolCarriesValuesMetadataAndAccessoryState() async throws {
        var graph = makeGraph()
        // Populate the depth the device adapter would produce after reads.
        graph.homes[0].rooms[0].accessories[0].services[0].characteristics[1].valueDescription = "65"
        graph.homes[0].rooms[0].accessories[0].services[0].characteristics[1].metadata =
            HomeGraph.CharacteristicMetadata(
                format: "float", units: "percentage", minValue: 0, maxValue: 100, step: 1
            )
        graph.homes[0].rooms[0].accessories[0].reachable = false
        graph.homes[0].rooms[0].accessories[0].bridged = true
        graph.homes[0].rooms[0].accessories[0].category = "com.apple.hap.lightbulb"
        graph.homes[0].rooms[0].accessories[0].firmwareVersion = "2.1.0"

        let registry = ReadToolRegistry(service: FakeHomeKitService(graph: graph))
        let rooms = try decode(
            await registry.call(name: "get_rooms", arguments: ["detail": .string("full")]),
            as: ReadToolRegistry.RoomsProjection<HomeGraph.Accessory>.self
        )
        let lamp = try #require(rooms.rooms.first?.accessories.first)
        #expect(lamp.reachable == false)
        #expect(lamp.bridged == true)
        #expect(lamp.category == "com.apple.hap.lightbulb")
        #expect(lamp.firmwareVersion == "2.1.0")
        let brightness = try #require(lamp.services.first?.characteristics.first { $0.type == brightnessType })
        #expect(brightness.valueDescription == "65")
        let metadata = try #require(brightness.metadata)
        #expect(metadata.format == "float")
        #expect(metadata.units == "percentage")
        #expect(metadata.minValue == 0)
        #expect(metadata.maxValue == 100)
        #expect(metadata.step == 1)
    }
    @Test func homesToolCarriesHubStateAndAuthorizationStatus() async throws {
        var graph = makeGraph()
        graph.homes[0].homeHubState = "connected"
        graph.authorizationStatus = "authorized"
        let registry = ReadToolRegistry(service: FakeHomeKitService(graph: graph))
        let homes = try decode(await registry.call(name: "get_homes"), as: ReadToolRegistry.HomesProjection.self)
        #expect(homes.authorizationStatus == "authorized")
        #expect(try #require(homes.homes.first).homeHubState == "connected")
    }

    @Test func scenesToolCarriesLastExecutionDate() async throws {
        let ran = Date(timeIntervalSince1970: 1_700_000_000)
        var graph = makeGraph()
        graph.homes[0].scenes[0].lastExecutionDate = ran
        let registry = ReadToolRegistry(service: FakeHomeKitService(graph: graph))
        let scenes = try decode(await registry.call(name: "get_scenes"), as: ReadToolRegistry.ScenesProjection.self)
        #expect(try #require(scenes.scenes.first).lastExecutionDate == ran)
    }

    @Test func triggersToolCarriesActivationStateRawAndNamed() async throws {
        var graph = makeGraph()
        graph.homes[0].triggers[0].triggerActivationState = nil // timer trigger
        graph.homes[0].triggers[1].triggerActivationState = 1
        let registry = ReadToolRegistry(service: FakeHomeKitService(graph: graph))
        let triggers = try decode(await registry.call(name: "get_triggers"), as: ReadToolRegistry.TriggersProjection.self)
        let timer = try #require(triggers.triggers.first { $0.id == "trig-timer" })
        #expect(timer.triggerActivationState == nil)
        #expect(timer.activationStateName == nil)
        let event = try #require(triggers.triggers.first { $0.id == "trig-event" })
        #expect(event.triggerActivationState == 1)
        #expect(event.activationStateName == "disabledNoHomeHub")
    }

    // MARK: - Fake execution stamps lastExecutionDate

    @Test func executingASceneStampsLastExecutionDate() async throws {
        let fake = FakeHomeKitService(graph: makeGraph())
        let before = try await fake.snapshot()
        #expect(before.homes.first?.scenes.first?.lastExecutionDate == nil)
        _ = try await fake.perform(.executeActionSet(homeId: "home-1", sceneId: "scene-movie"))
        let after = try await fake.snapshot()
        let stamped = try #require(after.homes.first?.scenes.first?.lastExecutionDate)
        #expect(stamped <= Date())
    }

    // MARK: - Fixtures

    private let brightnessType = "00000008-0000-1000-8000-0026BB765291"

    /// One home, one room, one accessory with On + Brightness, one scene,
    /// a timer and an event trigger.
    private func makeGraph() -> HomeGraph {
        HomeGraph(homes: [
            HomeGraph.Home(
                id: "home-1",
                name: "Main House",
                rooms: [
                    HomeGraph.Room(
                        id: "room-kitchen",
                        name: "Kitchen",
                        accessories: [
                            HomeGraph.Accessory(
                                id: "acc-kitchen-lamp",
                                name: "Kitchen Lamp",
                                services: [
                                    HomeGraph.AccessoryService(
                                        id: "svc-kitchen-lamp-light",
                                        name: "Kitchen Lamp",
                                        characteristics: [
                                            HomeGraph.CharacteristicRef(id: "char-kitchen-on", type: "On", name: "On"),
                                            HomeGraph.CharacteristicRef(
                                                id: "char-kitchen-brightness", type: brightnessType, name: "Brightness"
                                            ),
                                        ]
                                    )
                                ]
                            )
                        ]
                    )
                ],
                scenes: [
                    HomeGraph.Scene(
                        id: "scene-movie",
                        name: "Movie Night",
                        type: "AppleScene",
                        actions: [
                            HomeGraph.SceneAction(
                                accessoryId: "acc-kitchen-lamp",
                                accessoryName: "Kitchen Lamp",
                                service: nil,
                                characteristic: "On",
                                characteristicName: "On",
                                valueDescription: "true"
                            )
                        ]
                    )
                ],
                triggers: [
                    HomeGraph.Trigger(
                        id: "trig-timer",
                        name: "Morning Lamps",
                        isEnabled: false,
                        detail: .timer(fireDate: Date(timeIntervalSince1970: 0), recurrence: ["hour": 7])
                    ),
                    HomeGraph.Trigger(
                        id: "trig-event",
                        name: "Sunset Lights",
                        isEnabled: true,
                        detail: .event(events: [], predicate: nil)
                    ),
                ]
            )
        ])
    }

    private struct DecodingError: Error {}

    private func decode<T: Decodable>(_ result: MCP.CallTool.Result, as type: T.Type) throws -> T {
        guard case .some(.text(let text, _, _)) = result.content.first else {
            throw DecodingError()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(text.utf8))
    }
}
