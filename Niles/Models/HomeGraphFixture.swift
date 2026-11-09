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
                    Accessory(id: "acc-1", name: "Living Room Lamp"),
                    Accessory(id: "acc-2", name: "TV Backlight"),
                    Accessory(id: "acc-3", name: "Ceiling Fan"),
                ]),
                Room(id: "room-2", name: "Kitchen", accessories: [
                    Accessory(id: "acc-4", name: "Kitchen Lights"),
                    Accessory(id: "acc-5", name: "Coffee Maker"),
                ]),
                Room(id: "room-3", name: "Office", accessories: [
                    Accessory(id: "acc-6", name: "Desk Lamp"),
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
