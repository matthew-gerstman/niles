import Foundation
import MCP
import Testing
@testable import NilesCore

/// Read-tool tests over the fake service: fake -> registry -> serialized JSON.
/// No test touches `HMHomeManager`.
@Suite struct ReadToolRegistryTests {
    // MARK: - Fixtures

    // Well-known HomeKit type UUIDs (format 0x0000-1000-8000-0026BB765291):
    // 0x0008 brightness characteristic, 0x0043 lightbulb service,
    // 0x0025 switch-state characteristic (the event trigger's source),
    // 0x0049 switch service.
    private let brightness = "00000008-0000-1000-8000-0026BB765291"
    private let lightbulb = "00000043-0000-1000-8000-0026BB765291"
    private let powerEvent = "00000025-0000-1000-8000-0026BB765291"
    private let switchService = "00000049-0000-1000-8000-0026BB765291"

    /// One home, three rooms, one zone spanning two of them, a scene with one
    /// action, a service group holding a service (not an accessory), and an
    /// enabled event trigger plus a disabled timer trigger.
    private func makeGraph() -> HomeGraph {
        return HomeGraph(homes: [
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
                                        serviceType: lightbulb,
                                        characteristics: [
                                            HomeGraph.CharacteristicRef(id: "char-kitchen-on", type: powerEvent, name: "On"),
                                            HomeGraph.CharacteristicRef(id: "char-kitchen-brightness", type: brightness, name: "Brightness"),
                                        ]
                                    )
                                ]
                            )
                        ]
                    ),
                    HomeGraph.Room(
                        id: "room-office",
                        name: "Office",
                        accessories: [
                            HomeGraph.Accessory(
                                id: "acc-desk-lamp",
                                name: "Desk Lamp",
                                services: [
                                    HomeGraph.AccessoryService(
                                        id: "svc-desk-lamp-light",
                                        name: "Desk Lamp",
                                        serviceType: lightbulb,
                                        characteristics: [
                                            HomeGraph.CharacteristicRef(id: "char-desk-on", type: powerEvent, name: "On"),
                                            HomeGraph.CharacteristicRef(id: "char-desk-brightness", type: brightness, name: "Brightness"),
                                        ]
                                    )
                                ]
                            ),
                            // On/Off only — the non-dimmable control in the
                            // capability tests below.
                            HomeGraph.Accessory(
                                id: "acc-office-fan",
                                name: "Ceiling Fan",
                                services: [
                                    HomeGraph.AccessoryService(
                                        id: "svc-office-fan",
                                        name: "Ceiling Fan",
                                        serviceType: switchService,
                                        characteristics: [
                                            HomeGraph.CharacteristicRef(id: "char-fan-on", type: powerEvent, name: "On")
                                        ]
                                    )
                                ]
                            ),
                        ]
                    ),
                    HomeGraph.Room(id: "room-guest", name: "Guest Room", accessories: []),
                ],
                zones: [
                    HomeGraph.Zone(id: "zone-upstairs", name: "Upstairs", roomIds: ["room-office", "room-guest"])
                ],
                scenes: [
                    HomeGraph.Scene(
                        id: "scene-movie",
                        name: "Movie Night",
                        type: "AppleScene",
                        actions: [
                            HomeGraph.SceneAction(
                                accessoryId: "acc-desk-lamp",
                                accessoryName: "Desk Lamp",
                                service: "Lightbulb",
                                characteristic: brightness,
                                characteristicName: "Brightness",
                                valueDescription: "30"
                            )
                        ]
                    )
                ],
                serviceGroups: [
                    HomeGraph.ServiceGroup(
                        id: "group-lamps",
                        name: "Desk Lamps",
                        services: [
                            HomeGraph.ServiceRef(
                                id: "svc-desk-lamp-light",
                                name: "Desk Lamp Light",
                                serviceType: lightbulb,
                                accessoryId: "acc-desk-lamp",
                                accessoryName: "Desk Lamp"
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
                        detail: .event(
                            events: [HomeGraph.EventRef(type: "characteristic", characteristicType: powerEvent, valueDescription: "1")],
                            predicate: nil
                        )
                    ),
                ]
            )
        ])
    }

    private func makeRegistry(graph: HomeGraph) -> ReadToolRegistry {
        ReadToolRegistry(service: FakeHomeKitService(graph: graph))
    }

    private struct DecodingError: Error {}

    /// The text content is what agents actually read — decode that.
    private func decode<T: Decodable>(_ result: MCP.CallTool.Result, as type: T.Type) throws -> T {
        guard case .some(.text(let text, _, _)) = result.content.first else {
            throw DecodingError()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Data(text.utf8))
    }

    // MARK: - Tool listing

    @Test func listsSixReadOnlyTools() {
        let registry = ReadToolRegistry(service: FakeHomeKitService())
        #expect(
            registry.tools.map(\.name)
                == ["get_homes", "get_rooms", "get_zones", "get_scenes", "get_service_groups", "get_triggers"]
        )
        #expect(registry.tools.allSatisfy { $0.annotations.readOnlyHint == true })
    }

    // MARK: - Empty home

    @Test func emptyHomeGraphYieldsEmptySlices() async throws {
        let registry = ReadToolRegistry(service: FakeHomeKitService())
        for name in ["get_homes", "get_rooms", "get_zones", "get_scenes", "get_service_groups", "get_triggers"] {
            let result = await registry.call(name: name)
            guard result.isError == false else {
                Issue.record("\(name) failed on an empty graph: \(text(of: result))")
                continue
            }

            let json = try JSONSerialization.jsonObject(with: Data(text(of: result).utf8))
            let object = try #require(json as? [String: Any])
            let values = try #require(object.values.first as? [Any])
            #expect(values.isEmpty)
        }
    }

    // MARK: - Multi-room / zone graph

    @Test func homesToolSummarizesCounts() async throws {
        let registry = makeRegistry(graph: makeGraph())
        let homes = try decode(await registry.call(name: "get_homes"), as: ReadToolRegistry.HomesProjection.self)
        let home = try #require(homes.homes.first)
        #expect(home.id == "home-1")
        #expect(home.name == "Main House")
        #expect(home.summary.rooms == 3)
        #expect(home.summary.zones == 1)
        #expect(home.summary.accessories == 3)
        #expect(home.summary.scenes == 1)
        #expect(home.summary.serviceGroups == 1)
        #expect(home.summary.triggers == 2)
    }

    @Test func roomsToolCarriesAccessoryAndZoneMembership() async throws {
        let registry = makeRegistry(graph: makeGraph())
        let rooms = try decode(await registry.call(name: "get_rooms"), as: ReadToolRegistry.RoomsProjection.self)

        let office = try #require(rooms.rooms.first { $0.id == "room-office" })
        #expect(office.homeName == "Main House")
        #expect(office.zoneId == "zone-upstairs")
        #expect(office.zoneName == "Upstairs")
        #expect(office.accessories.map(\.name) == ["Desk Lamp", "Ceiling Fan"])

        // The Kitchen is in no zone; membership must stay nil, not empty-string.
        let kitchen = try #require(rooms.rooms.first { $0.id == "room-kitchen" })
        #expect(kitchen.zoneId == nil)
        #expect(kitchen.zoneName == nil)
        #expect(kitchen.accessories.map(\.name) == ["Kitchen Lamp"])
    }

    @Test func roomsToolExposesServiceCapabilitiesPerAccessory() async throws {
        let registry = makeRegistry(graph: makeGraph())
        let rooms = try decode(await registry.call(name: "get_rooms"), as: ReadToolRegistry.RoomsProjection.self)

        // The dimmable bulb: its lightbulb service lists Brightness.
        let kitchen = try #require(rooms.rooms.first { $0.id == "room-kitchen" })
        let lamp = try #require(kitchen.accessories.first { $0.id == "acc-kitchen-lamp" })
        let lampLight = try #require(lamp.services.first { $0.serviceType == lightbulb })
        #expect(lampLight.characteristics.map(\.type) == [powerEvent, brightness])

        // The On/Off-only switch: no Brightness anywhere on the accessory.
        let office = try #require(rooms.rooms.first { $0.id == "room-office" })
        let fan = try #require(office.accessories.first { $0.id == "acc-office-fan" })
        #expect(fan.services.flatMap(\.characteristics).map(\.type) == [powerEvent])
        #expect(!fan.services.contains { service in service.characteristics.contains { $0.type == brightness } })
    }

    @Test func zonesToolCarriesMemberRooms() async throws {
        let registry = makeRegistry(graph: makeGraph())
        let zones = try decode(await registry.call(name: "get_zones"), as: ReadToolRegistry.ZonesProjection.self)
        let upstairs = try #require(zones.zones.first)
        #expect(upstairs.name == "Upstairs")
        #expect(upstairs.rooms.map(\.id) == ["room-office", "room-guest"])
    }

    @Test func scenesToolCarriesActionsWithTargetValues() async throws {
        let registry = makeRegistry(graph: makeGraph())
        let scenes = try decode(await registry.call(name: "get_scenes"), as: ReadToolRegistry.ScenesProjection.self)
        let movie = try #require(scenes.scenes.first)
        #expect(movie.name == "Movie Night")
        #expect(movie.type == "AppleScene")
        let action = try #require(movie.actions.first)
        #expect(action.accessoryName == "Desk Lamp")
        #expect(action.valueDescription == "30")
    }

    @Test func serviceGroupsToolGroupsServicesNotAccessories() async throws {
        let registry = makeRegistry(graph: makeGraph())
        let groups = try decode(await registry.call(name: "get_service_groups"), as: ReadToolRegistry.ServiceGroupsProjection.self)
        let lamps = try #require(groups.serviceGroups.first)
        let service = try #require(lamps.services.first)
        // The spec's conflation guard: a group's members are services, and
        // each service bridges to its owning accessory.
        #expect(service.id == "svc-desk-lamp-light")
        #expect(service.serviceType != nil)
        #expect(service.accessoryId == "acc-desk-lamp")
        #expect(service.accessoryName == "Desk Lamp")
    }

    // MARK: - Trigger serialization

    @Test func disabledTimerTriggerSerializesFireDateAndRecurrence() async throws {
        let registry = makeRegistry(graph: makeGraph())
        let triggers = try decode(await registry.call(name: "get_triggers"), as: ReadToolRegistry.TriggersProjection.self)
        let morning = try #require(triggers.triggers.first { $0.id == "trig-timer" })
        #expect(morning.isEnabled == false)
        guard case .timer(let fireDate, let recurrence) = morning.detail else {
            Issue.record("expected a timer trigger, got \(morning.detail)")
            return
        }
        #expect(fireDate == Date(timeIntervalSince1970: 0))
        #expect(recurrence == ["hour": 7])
    }

    @Test func enabledEventTriggerSerializesEventsAndPredicate() async throws {
        let registry = makeRegistry(graph: makeGraph())
        let triggers = try decode(await registry.call(name: "get_triggers"), as: ReadToolRegistry.TriggersProjection.self)
        let sunset = try #require(triggers.triggers.first { $0.id == "trig-event" })
        #expect(sunset.isEnabled == true)
        guard case .event(let events, let predicate) = sunset.detail else {
            Issue.record("expected an event trigger, got \(sunset.detail)")
            return
        }
        #expect(events.first?.type == "characteristic")
        #expect(predicate == nil)
    }

    @Test func unknownTriggerKindSerializesAsUnknown() async throws {
        var graph = makeGraph()
        graph.homes[0].triggers.append(
            HomeGraph.Trigger(id: "trig-mystery", name: "Mystery", isEnabled: true, detail: .unknown(kind: "HMFutureTrigger"))
        )
        let registry = makeRegistry(graph: graph)
        let triggers = try decode(await registry.call(name: "get_triggers"), as: ReadToolRegistry.TriggersProjection.self)
        let mystery = try #require(triggers.triggers.first { $0.id == "trig-mystery" })
        #expect(mystery.detail == .unknown(kind: "HMFutureTrigger"))
    }

    @Test func recurrenceComponentsMapToJSONFriendlyDictionary() {
        var components = DateComponents()
        components.hour = 7
        components.minute = 30
        components.second = 0

        #expect(HomeManagerHomeKitService.recurrenceValues(from: components) == ["hour": 7, "minute": 30])
        #expect(HomeManagerHomeKitService.recurrenceValues(from: nil) == [:])
    }

    // MARK: - Error paths

    @Test func unknownToolIsAnInBandError() async {
        let registry = ReadToolRegistry(service: FakeHomeKitService())
        let result = await registry.call(name: "set_room_contents")
        #expect(result.isError == true)
        #expect(text(of: result).contains("get_homes"))
    }

    @Test func graphReadFailureSurfacesAsToolError() async {
        struct ThrowingHomeKitService: HomeKitService {
            func snapshot() async throws -> HomeGraph {
                throw HomeKitServiceError.homeLoadTimedOut
            }
        }
        let registry = ReadToolRegistry(service: ThrowingHomeKitService())
        let result = await registry.call(name: "get_homes")
        #expect(result.isError == true)
    }

    // MARK: - Helpers

    private func text(of result: MCP.CallTool.Result) -> String {
        guard case .some(.text(let text, _, _)) = result.content.first else { return "" }
        return text
    }
}
