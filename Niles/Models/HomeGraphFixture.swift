import Foundation
import NilesCore

/// A representative home for the simulator and previews.
///
/// The simulator cannot reach a real HomeKit database, so simulator builds run
/// the proposal pipeline against `FakeHomeKitService` seeded from here — the
/// same fake the unit tests use. Real-device builds use `HMHomeManager` instead.
extension HomeGraph {
    static var demoFixture: HomeGraph {
        let home = Home(
            id: "home-1",
            name: "Gerstman Home",
            rooms: [
                Room(id: "room-1", name: "Living Room", accessories: [
                    Accessory(id: "acc-1", name: "Living Room Lamp", services: [
                        AccessoryService(
                            id: "service-acc-1-light", name: "Living Room Lamp", serviceType: "Lightbulb",
                            characteristics: [
                                CharacteristicRef(id: "char-acc-1-on", type: "On", name: "On"),
                                CharacteristicRef(id: "char-acc-1-brightness", type: "Brightness", name: "Brightness"),
                            ]
                        ),
                    ]),
                    Accessory(id: "acc-2", name: "TV Backlight", services: [
                        AccessoryService(
                            id: "service-acc-2-light", name: "TV Backlight", serviceType: "Lightbulb",
                            characteristics: [CharacteristicRef(id: "char-acc-2-on", type: "On", name: "On")]
                        ),
                    ]),
                    Accessory(id: "acc-3", name: "Ceiling Fan", services: [
                        AccessoryService(
                            id: "service-acc-3-fan", name: "Ceiling Fan", serviceType: "Fan",
                            characteristics: [CharacteristicRef(id: "char-acc-3-on", type: "On", name: "On")]
                        ),
                    ]),
                ]),
                Room(id: "room-2", name: "Kitchen", accessories: [
                    Accessory(id: "acc-4", name: "Kitchen Lights", services: [
                        AccessoryService(
                            id: "service-acc-4-light", name: "Kitchen Lights", serviceType: "Lightbulb",
                            characteristics: [
                                CharacteristicRef(id: "char-acc-4-on", type: "On", name: "On"),
                                CharacteristicRef(id: "char-acc-4-brightness", type: "Brightness", name: "Brightness"),
                            ]
                        ),
                    ]),
                    Accessory(id: "acc-5", name: "Coffee Maker", services: [
                        AccessoryService(
                            id: "service-acc-5-switch", name: "Coffee Maker", serviceType: "Switch",
                            characteristics: [CharacteristicRef(id: "char-acc-5-on", type: "On", name: "On")]
                        ),
                    ]),
                ]),
                Room(id: "room-3", name: "Office", accessories: [
                    Accessory(id: "acc-6", name: "Desk Lamp", services: [
                        AccessoryService(
                            id: "service-acc-6-light", name: "Desk Lamp", serviceType: "Lightbulb",
                            characteristics: [
                                CharacteristicRef(id: "char-acc-6-on", type: "On", name: "On"),
                                CharacteristicRef(id: "char-acc-6-brightness", type: "Brightness", name: "Brightness"),
                            ]
                        ),
                    ]),
                ]),
            ],
            zones: [
                Zone(id: "zone-1", name: "Downstairs", roomIds: ["room-1", "room-2"]),
            ],
            scenes: [
                Scene(id: "scene-1", name: "Good Morning", type: "AppleScene", actions: [
                    SceneAction(
                        accessoryId: "acc-4",
                        accessoryName: "Kitchen Lights",
                        service: "Lightbulb",
                        characteristic: "On",
                        characteristicName: "On",
                        valueDescription: "1"
                    ),
                ]),
            ],
            serviceGroups: [
                ServiceGroup(id: "group-1", name: "Desk Lamps", services: [
                    ServiceRef(
                        id: "service-1",
                        name: "Desk Lamp Light",
                        serviceType: "Lightbulb",
                        accessoryId: "acc-6",
                        accessoryName: "Desk Lamp"
                    ),
                ]),
            ],
            triggers: [
                Trigger(
                    id: "trigger-1",
                    name: "Evening lights",
                    isEnabled: true,
                    detail: .timer(fireDate: Date(timeIntervalSince1970: 75_351_600), recurrence: ["weekday": 2, "hour": 17, "minute": 30])
                ),
            ]
        )
        return HomeGraph(homes: [home])
    }
}
