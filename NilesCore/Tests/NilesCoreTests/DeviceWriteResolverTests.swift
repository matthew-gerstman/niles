import Foundation
import Testing
@testable import NilesCore

/// The pure resolver half of the device executor: every staged operation
/// translates to ordered, concretely-resolved steps against a fixture view
/// of the live home — with typed errors for drift, duplicate names, and
/// constraint violations. No test touches `HMHomeManager`.
@Suite struct DeviceWriteResolverTests {
    // MARK: - Fixtures

    private let fireDate = Date(timeIntervalSince1970: 1_762_592_400) // minute boundary

    /// Light A (Kitchen): Lightbulb service with `On` (bool metadata) and
    /// `Brightness` (int metadata). Lamp B (Living Room) adds a Speaker
    /// service with `Volume` (float) and `TrackName` (string metadata).
    /// Characteristics carry names like the live mapping does.
    private func fixtureView() -> DeviceHomeView {
        let onA = DeviceHomeView.Characteristic(id: "char-on-a", type: "On", name: "On", kind: .number)
        let brightnessA = DeviceHomeView.Characteristic(id: "char-brightness-a", type: "Brightness", name: "Brightness", kind: .number)
        let lightbulbA = DeviceHomeView.Service(id: "svc-light-a", name: "Lightbulb", serviceType: "Lightbulb", characteristics: [onA, brightnessA])
        let lightA = DeviceHomeView.Accessory(id: "acc-light-a", name: "Light A", services: [lightbulbA])

        let onB = DeviceHomeView.Characteristic(id: "char-on-b", type: "On", name: "On", kind: .number)
        let brightnessB = DeviceHomeView.Characteristic(id: "char-brightness-b", type: "Brightness", name: "Brightness", kind: .number)
        let lightbulbB = DeviceHomeView.Service(id: "svc-light-b", name: "Lightbulb", serviceType: "Lightbulb", characteristics: [onB, brightnessB])
        let volumeB = DeviceHomeView.Characteristic(id: "char-volume-b", type: "Volume", name: "Volume", kind: .number)
        let trackB = DeviceHomeView.Characteristic(id: "char-track-b", type: "TrackName", name: "Track Name", kind: .string)
        let speakerB = DeviceHomeView.Service(id: "svc-speaker-b", name: "Speaker", serviceType: "Speaker", characteristics: [volumeB, trackB])
        let lampB = DeviceHomeView.Accessory(id: "acc-lamp-b", name: "Lamp B", services: [lightbulbB, speakerB])

        let home = DeviceHomeView.Home(
            id: "home-1",
            name: "Townhouse",
            rooms: [
                DeviceHomeView.Room(id: "room-kitchen", name: "Kitchen", accessoryIds: ["acc-light-a"]),
                DeviceHomeView.Room(id: "room-living", name: "Living Room", accessoryIds: ["acc-lamp-b"]),
                DeviceHomeView.Room(id: "room-office", name: "Office"),
            ],
            zones: [DeviceHomeView.Zone(id: "zone-upstairs", name: "Upstairs", roomIds: ["room-kitchen"])],
            scenes: [
                DeviceHomeView.Scene(
                    id: "scene-chill",
                    name: "Chill",
                    actionKeys: [
                        SceneActionKey(
                            accessoryId: "acc-light-a", service: "Lightbulb",
                            characteristic: "On", valueDescription: "1"
                        )
                    ]
                )
            ],
            serviceGroups: [
                DeviceHomeView.ServiceGroup(id: "group-all", name: "Everything", serviceIds: ["svc-light-a"])
            ],
            triggers: [
                DeviceHomeView.Trigger(
                    id: "trigger-timer", name: "Sunset lights", isEnabled: true,
                    timerFireDate: fireDate, timerRecurrence: ["hour": 7, "minute": 30],
                    linkedSceneIds: ["scene-chill"]
                ),
                DeviceHomeView.Trigger(
                    id: "trigger-event", name: "Motion alert", isEnabled: false,
                    timerFireDate: nil
                ),
            ],
            accessories: [lightA, lampB]
        )
        // A second home so cross-home duplicate-name rules have something to
        // catch and per-home room scoping is exercised.
        let other = DeviceHomeView.Home(
            id: "home-2",
            name: "Beach House",
            scenes: [DeviceHomeView.Scene(id: "scene-beach", name: "Beach Mode")]
        )
        return DeviceHomeView(homes: [home, other])
    }

    private func resolve(_ operation: HomeKitOperation, view: DeviceHomeView? = nil) throws -> [DeviceWriteStep] {
        try DeviceWriteResolver.resolve(operation, in: view ?? fixtureView())
    }

    private func error(_ body: () throws -> Void) -> HomeKitWriteError? {
        do {
            try body()
            return nil
        } catch let error as HomeKitWriteError {
            return error
        } catch {
            Issue.record("Unexpected error type: \(error)")
            return nil
        }
    }

    // MARK: Rooms

    @Test func addRoomResolvesAgainstItsHome() throws {
        let steps = try resolve(.addRoom(homeId: "home-1", name: "Den"))
        #expect(steps == [.addRoom(homeId: "home-1", name: "Den")])
    }

    @Test func addRoomRejectsDuplicateNameInItsHome() {
        let thrown = error {
            _ = try self.resolve(.addRoom(homeId: "home-1", name: "LIVING room"))
        }
        #expect(thrown == .duplicateName("Home already has a room named “LIVING room”."))
    }

    @Test func addRoomRejectsDriftedHome() {
        #expect(error { _ = try self.resolve(.addRoom(homeId: "home-x", name: "Den")) }
            == .objectMissing("No home home-x."))
    }

    @Test func renameRoomResolvesTheRoom() throws {
        let steps = try resolve(.renameRoom(homeId: "home-1", roomId: "room-office", to: "Studio"))
        #expect(steps == [.renameRoom(homeId: "home-1", roomId: "room-office", to: "Studio")])
        #expect(error { _ = try self.resolve(.renameRoom(homeId: "home-1", roomId: "room-x", to: "Studio")) }
            == .objectMissing("No room room-x."))
    }

    @Test func removeRoomResolvesTheRoom() throws {
        let steps = try resolve(.removeRoom(homeId: "home-1", roomId: "room-office"))
        #expect(steps == [.removeRoom(homeId: "home-1", roomId: "room-office")])
        #expect(error { _ = try self.resolve(.removeRoom(homeId: "home-1", roomId: "room-x")) }
            == .objectMissing("No room room-x."))
    }

    // MARK: Zones

    @Test func setZoneRoomsResolvesMembershipDiff() throws {
        let steps = try resolve(.setZoneRooms(
            homeId: "home-1", zoneId: "zone-upstairs",
            addRoomIds: ["room-office"], removeRoomIds: ["room-kitchen"]
        ))
        #expect(steps == [.updateZoneRooms(
            homeId: "home-1", zoneId: "zone-upstairs",
            addRoomIds: ["room-office"], removeRoomIds: ["room-kitchen"]
        )])
    }

    @Test func setZoneRoomsRejectsRemovingARoomThatIsNotAMember() {
        #expect(error {
            _ = try self.resolve(.setZoneRooms(
                homeId: "home-1", zoneId: "zone-upstairs", addRoomIds: [], removeRoomIds: ["room-office"]
            ))
        } == .objectMissing("Zone “Upstairs” does not contain room room-office."))
    }

    @Test func setZoneRoomsRejectsAddingAnUnknownRoom() {
        #expect(error {
            _ = try self.resolve(.setZoneRooms(
                homeId: "home-1", zoneId: "zone-upstairs", addRoomIds: ["room-x"], removeRoomIds: []
            ))
        } == .objectMissing("No room room-x to add to zone “Upstairs”."))
    }

    @Test func setZoneRoomsRejectsAZoneThatVanishedSinceStaging() {
        // Execution re-resolves every id against the live graph; a zone
        // deleted between staging and approval fails loudly, naming the id.
        #expect(error {
            _ = try self.resolve(.setZoneRooms(
                homeId: "home-1", zoneId: "zone-gone", addRoomIds: ["room-kitchen"], removeRoomIds: []
            ))
        } == .objectMissing("No zone zone-gone."))
    }

    // MARK: Zone create, rename, delete

    @Test func createZoneResolvesAndRejectsDuplicateName() throws {
        let steps = try resolve(.createZone(homeId: "home-1", name: "Downstairs"))
        #expect(steps == [.createZone(homeId: "home-1", name: "Downstairs")])
        #expect(error {
            _ = try self.resolve(.createZone(homeId: "home-1", name: "upstairs"))
        } == .duplicateName("Home already has a zone named “upstairs”."))
        // Zones are scoped per home — the other home's names never collide.
        #expect(try resolve(.createZone(homeId: "home-2", name: "Upstairs")) ==
            [.createZone(homeId: "home-2", name: "Upstairs")])
    }

    @Test func createZoneRejectsDriftedHome() {
        #expect(error { _ = try self.resolve(.createZone(homeId: "home-x", name: "Downstairs")) }
            == .objectMissing("No home home-x."))
    }

    @Test func renameZoneResolvesTheZone() throws {
        let steps = try resolve(.renameZone(homeId: "home-1", zoneId: "zone-upstairs", to: "Top Floor"))
        #expect(steps == [.renameZone(homeId: "home-1", zoneId: "zone-upstairs", to: "Top Floor")])
        #expect(error { _ = try self.resolve(.renameZone(homeId: "home-1", zoneId: "zone-x", to: "Top Floor")) }
            == .objectMissing("No zone zone-x."))
    }

    @Test func renameZoneRejectsDuplicateNameInItsHome() throws {
        var view = fixtureView()
        view.homes[0].zones.append(DeviceHomeView.Zone(id: "zone-downstairs", name: "Downstairs"))
        #expect(error {
            _ = try self.resolve(.renameZone(homeId: "home-1", zoneId: "zone-upstairs", to: "downstairs"), view: view)
        } == .duplicateName("Home already has a zone named “downstairs”."))
        // Case-insensitively renaming a zone to its own name is legal — the
        // executor's updateName accepts it; nothing here needs to reject.
        let steps = try resolve(.renameZone(homeId: "home-1", zoneId: "zone-upstairs", to: "UPSTAIRS"), view: view)
        #expect(steps == [.renameZone(homeId: "home-1", zoneId: "zone-upstairs", to: "UPSTAIRS")])
    }

    @Test func removeZoneResolvesTheZone() throws {
        // Zone delete preserves rooms by construction — the resolver only
        // removes the zone object; rooms are never touched.
        let steps = try resolve(.removeZone(homeId: "home-1", zoneId: "zone-upstairs"))
        #expect(steps == [.removeZone(homeId: "home-1", zoneId: "zone-upstairs")])
        #expect(error { _ = try self.resolve(.removeZone(homeId: "home-1", zoneId: "zone-x")) }
            == .objectMissing("No zone zone-x."))
    }

    // MARK: Scenes

    @Test func addActionSetResolvesActionsToCharacteristics() throws {
        let steps = try resolve(.addActionSet(
            homeId: "home-1", name: "Movie Night",
            actions: [
                SceneActionSpec(accessoryId: "acc-light-a", service: "Lightbulb", characteristic: "Brightness", value: .int(30)),
                SceneActionSpec(accessoryId: "acc-lamp-b", service: nil, characteristic: "TrackName", value: .string("Radiohead")),
            ]
        ))
        guard case .createActionSet(let homeId, let name, let actions)? = steps.first, actions.count == 2 else {
            Issue.record("Expected one createActionSet step with two actions, got \(steps)")
            return
        }
        #expect(homeId == "home-1" && name == "Movie Night")
        #expect(actions[0] == ResolvedAction(
            accessoryId: "acc-light-a", serviceId: "svc-light-a",
            characteristicId: "char-brightness-a", characteristicType: "Brightness",
            kind: .number, value: .int(30)
        ))
        #expect(actions[1] == ResolvedAction(
            accessoryId: "acc-lamp-b", serviceId: "svc-speaker-b",
            characteristicId: "char-track-b", characteristicType: "TrackName",
            kind: .string, value: .string("Radiohead")
        ))
    }

    @Test func addActionSetRejectsDuplicateSceneNameAcrossHomes() {
        #expect(error {
            _ = try self.resolve(.addActionSet(homeId: "home-1", name: "beach mode", actions: []))
        } == .duplicateName("Home already has a scene named “beach mode”."))
    }

    @Test func addActionSetRejectsUnknownAccessory() {
        #expect(error {
            _ = try self.resolve(.addActionSet(
                homeId: "home-1", name: "Movie Night",
                actions: [SceneActionSpec(accessoryId: "acc-x", service: nil, characteristic: "On", value: .bool(true))]
            ))
        } == .objectMissing("No accessory acc-x in home “Townhouse”."))
    }

    @Test func addActionSetRejectsUnknownCharacteristicType() {
        #expect(error {
            _ = try self.resolve(.addActionSet(
                homeId: "home-1", name: "Movie Night",
                actions: [SceneActionSpec(accessoryId: "acc-light-a", service: nil, characteristic: "Hue", value: .int(240))]
            ))
        } == .objectMissing("Accessory “Light A” has no service with characteristic Hue."))
    }

    @Test func addActionSetRejectsAStringOnANumberCharacteristic() {
        #expect(error {
            _ = try self.resolve(.addActionSet(
                homeId: "home-1", name: "Movie Night",
                actions: [SceneActionSpec(accessoryId: "acc-lamp-b", service: "Speaker", characteristic: "Volume", value: .string("loud"))]
            ))
        }?.isInvalidOperation == true)
    }

    @Test func setSceneActionsResolvesAddsAndCarriesRemoveKeys() throws {
        let removeKey = SceneActionKey(
            accessoryId: "acc-light-a", service: "Lightbulb",
            characteristic: "On", valueDescription: "1"
        )
        let steps = try resolve(.setSceneActions(
            homeId: "home-1", sceneId: "scene-chill",
            add: [SceneActionSpec(accessoryId: "acc-lamp-b", service: nil, characteristic: "Brightness", value: .double(40))],
            remove: [removeKey]
        ))
        guard case .updateSceneActions(let homeId, let sceneId, let add, let remove)? = steps.first else {
            Issue.record("Expected one updateSceneActions step, got \(steps)")
            return
        }
        #expect(homeId == "home-1" && sceneId == "scene-chill" && remove == [removeKey])
        #expect(add.count == 1 && add[0].characteristicId == "char-brightness-b")
        #expect(error {
            _ = try self.resolve(.setSceneActions(homeId: "home-1", sceneId: "scene-x", add: [], remove: []))
        } == .objectMissing("No scene scene-x."))
    }

    // MARK: Characteristic name and UUID matching

    /// Built like `HomeManagerHomeKitService.homeView(from:)` fills it on
    /// device: `type` carries the HomeKit type UUID, the friendly name lives
    /// in `name`.
    private func liveShapedView() -> DeviceHomeView {
        let on = DeviceHomeView.Characteristic(
            id: "char-on-live", type: "00000025-0000-1000-8000-0026BB765291", name: "On", kind: .number
        )
        let brightness = DeviceHomeView.Characteristic(
            id: "char-brightness-live", type: "00000008-0000-1000-8000-0026BB765291", name: "Brightness", kind: .number
        )
        let lightbulb = DeviceHomeView.Service(
            id: "svc-light-live", name: "Lightbulb", serviceType: "00000043-0000-1000-8000-0026BB765291",
            characteristics: [on, brightness]
        )
        let light = DeviceHomeView.Accessory(id: "acc-light-live", name: "Light A", services: [lightbulb])
        return DeviceHomeView(homes: [DeviceHomeView.Home(id: "home-live", name: "Townhouse", accessories: [light])])
    }

    @Test func addActionSetResolvesFriendlyNameAndUUIDSpellingsOnALiveShapedView() throws {
        for spelling in ["Brightness", "brightness", "00000008-0000-1000-8000-0026BB765291"] {
            let steps = try resolve(.addActionSet(
                homeId: "home-live", name: "Movie Night",
                actions: [SceneActionSpec(accessoryId: "acc-light-live", service: nil, characteristic: spelling, value: .int(30))]
            ), view: liveShapedView())
            guard case .createActionSet(_, _, let actions)? = steps.first, actions.count == 1 else {
                Issue.record("Expected one createActionSet step for \(spelling), got \(steps)")
                continue
            }
            #expect(actions[0].characteristicId == "char-brightness-live")
            #expect(actions[0].characteristicType == "00000008-0000-1000-8000-0026BB765291")
        }
    }

    @Test func addActionSetRejectsAnUnknownNameOnALiveShapedView() {
        #expect(error {
            _ = try self.resolve(.addActionSet(
                homeId: "home-live", name: "Movie Night",
                actions: [SceneActionSpec(accessoryId: "acc-light-live", service: nil, characteristic: "Hue", value: .int(240))]
            ), view: liveShapedView())
        } == .objectMissing("Accessory “Light A” has no service with characteristic Hue."))
    }

    @Test func addEventTriggerResolvesTheCharacteristicByFriendlyNameOnALiveShapedView() throws {
        let steps = try resolve(.addEventTrigger(
            homeId: "home-live", name: "Evening",
            events: [.characteristic(accessoryId: "acc-light-live", characteristic: "Brightness", value: .int(30))],
            endEvents: [], executeOnce: false,
            sceneId: nil
        ), view: liveShapedView())
        #expect(steps == [.createEventTrigger(
            homeId: "home-live", name: "Evening",
            events: [.characteristic(
                id: "char-brightness-live", type: "00000008-0000-1000-8000-0026BB765291", value: .number(.int(30))
            )],
            endEvents: [], executeOnce: false,
            sceneId: nil
        )])
    }

    // MARK: Direct characteristic writes

    /// The live-shaped view with declared metadata on Brightness — the
    /// device view now carries the graph's read-depth metadata, so the
    /// resolver can range-check direct writes.
    private func rangedLiveView() -> DeviceHomeView {
        var view = liveShapedView()
        view.homes[0].accessories[0].services[0].characteristics[1].metadata =
            HomeGraph.CharacteristicMetadata(format: "int", units: "percentage", minValue: 0, maxValue: 100, step: 1)
        return view
    }

    @Test func writeCharacteristicResolvesFriendlyNameAndUUIDSpellingsOnALiveShapedView() throws {
        for spelling in ["Brightness", "brightness", "00000008-0000-1000-8000-0026BB765291"] {
            let steps = try resolve(
                .writeCharacteristic(
                    homeId: "home-live",
                    action: SceneActionSpec(accessoryId: "acc-light-live", service: nil, characteristic: spelling, value: .int(30))
                ),
                view: liveShapedView()
            )
            #expect(steps == [.writeCharacteristic(
                homeId: "home-live",
                action: ResolvedAction(
                    accessoryId: "acc-light-live",
                    serviceId: "svc-light-live",
                    characteristicId: "char-brightness-live",
                    characteristicType: "00000008-0000-1000-8000-0026BB765291",
                    kind: .number,
                    value: .int(30)
                )
            )])
        }
    }

    @Test func writeCharacteristicResolvesEveryValueKind() throws {
        // A bool onto a number-kind characteristic (the light switch shape).
        let on = try resolve(
            .writeCharacteristic(
                homeId: "home-1",
                action: SceneActionSpec(accessoryId: "acc-light-a", service: nil, characteristic: "On", value: .bool(true))
            )
        )
        #expect(on == [.writeCharacteristic(
            homeId: "home-1",
            action: ResolvedAction(
                accessoryId: "acc-light-a",
                serviceId: "svc-light-a",
                characteristicId: "char-on-a",
                characteristicType: "On",
                kind: .number,
                value: .bool(true)
            )
        )])
        // A string onto a string-kind characteristic.
        let track = try resolve(
            .writeCharacteristic(
                homeId: "home-1",
                action: SceneActionSpec(accessoryId: "acc-lamp-b", service: nil, characteristic: "TrackName", value: .string("Radiohead"))
            )
        )
        #expect(track == [.writeCharacteristic(
            homeId: "home-1",
            action: ResolvedAction(
                accessoryId: "acc-lamp-b",
                serviceId: "svc-speaker-b",
                characteristicId: "char-track-b",
                characteristicType: "TrackName",
                kind: .string,
                value: .string("Radiohead")
            )
        )])
    }

    @Test func writeCharacteristicRejectsAStringOnANumberCharacteristic() {
        let thrown = error {
            _ = try self.resolve(
                .writeCharacteristic(
                    homeId: "home-1",
                    action: SceneActionSpec(accessoryId: "acc-lamp-b", service: nil, characteristic: "Volume", value: .string("loud"))
                )
            )
        }
        guard case .invalidOperation(let message)? = thrown else {
            Issue.record("Expected invalidOperation, got \(String(describing: thrown))")
            return
        }
        #expect(message.contains("Volume"))
        #expect(message.contains("holds numbers"))
    }

    @Test func writeCharacteristicRejectsValuesOutsideTheDeclaredRange() {
        let thrown = error {
            _ = try self.resolve(
                .writeCharacteristic(
                    homeId: "home-live",
                    action: SceneActionSpec(accessoryId: "acc-light-live", service: nil, characteristic: "Brightness", value: .int(150))
                ),
                view: rangedLiveView()
            )
        }
        guard case .invalidOperation(let message)? = thrown else {
            Issue.record("Expected invalidOperation, got \(String(describing: thrown))")
            return
        }
        #expect(message.contains("150"))
        #expect(message.contains("0…100"))
    }

    @Test func writeCharacteristicRejectsValuesOutsideTheDeclaredValidValues() {
        var view = rangedLiveView()
        view.homes[0].accessories[0].services[0].characteristics[1].metadata?.validValues = [0, 50, 100]
        let thrown = error {
            _ = try self.resolve(
                .writeCharacteristic(
                    homeId: "home-live",
                    action: SceneActionSpec(accessoryId: "acc-light-live", service: nil, characteristic: "Brightness", value: .int(51))
                ),
                view: view
            )
        }
        guard case .invalidOperation(let message)? = thrown else {
            Issue.record("Expected invalidOperation, got \(String(describing: thrown))")
            return
        }
        #expect(message.contains("0, 50, 100"))
        #expect(message.contains("51"))
    }

    @Test func writeCharacteristicRejectsAnUnknownCharacteristic() {
        #expect(error {
            _ = try self.resolve(
                .writeCharacteristic(
                    homeId: "home-live",
                    action: SceneActionSpec(accessoryId: "acc-light-live", service: nil, characteristic: "Hue", value: .int(30))
                ),
                view: liveShapedView()
            )
        } == .objectMissing("Accessory “Light A” has no service with characteristic Hue."))
    }

    @Test func valueViolationChecksKindRangeAndValidValuesTogether() {
        var metadata = HomeGraph.CharacteristicMetadata(format: "int", units: nil, minValue: 0, maxValue: 100, step: 1)
        // Kind mismatch outranges metadata checks.
        #expect(DeviceWriteResolver.valueViolation(.string("loud"), kind: .number, metadata: metadata) != nil)
        // With no metadata, a kind-compatible value is fine.
        #expect(DeviceWriteResolver.valueViolation(.int(42), kind: .number, metadata: nil) == nil)
        // Out of the declared range.
        #expect(DeviceWriteResolver.valueViolation(.int(150), kind: .number, metadata: metadata)?.contains("out of range") == true)
        // Inside the range passes.
        #expect(DeviceWriteResolver.valueViolation(.int(50), kind: .number, metadata: metadata) == nil)
        // Declared valid values constrain further than the range.
        metadata.validValues = [0, 100]
        #expect(DeviceWriteResolver.valueViolation(.int(50), kind: .number, metadata: metadata)?.contains("0, 100") == true)
    }

    // MARK: Scene rename, delete, execute

    @Test func renameActionSetResolvesTheScene() throws {
        let steps = try resolve(.renameActionSet(homeId: "home-1", sceneId: "scene-chill", to: "Evening"))
        #expect(steps == [.renameActionSet(homeId: "home-1", sceneId: "scene-chill", to: "Evening")])
    }

    @Test func renameActionSetToTheSameNameResolves() throws {
        // Case-insensitive no-op rename is legal — the executor's updateName
        // accepts it; nothing here needs to reject.
        let steps = try resolve(.renameActionSet(homeId: "home-1", sceneId: "scene-chill", to: "chill"))
        #expect(steps == [.renameActionSet(homeId: "home-1", sceneId: "scene-chill", to: "chill")])
    }

    @Test func renameActionSetRejectsDuplicateNameAcrossHomes() {
        #expect(error {
            _ = try self.resolve(.renameActionSet(homeId: "home-1", sceneId: "scene-chill", to: "Beach Mode"))
        } == .duplicateName("Home already has a scene named “Beach Mode”."))
        #expect(error {
            _ = try self.resolve(.renameActionSet(homeId: "home-2", sceneId: "scene-beach", to: "Chill"))
        } == .duplicateName("Home already has a scene named “Chill”."))
    }

    @Test func renameActionSetRejectsMissingScene() {
        #expect(error {
            _ = try self.resolve(.renameActionSet(homeId: "home-1", sceneId: "scene-x", to: "Evening"))
        } == .objectMissing("No scene scene-x."))
    }

    @Test func removeActionSetResolvesTheScene() throws {
        let steps = try resolve(.removeActionSet(homeId: "home-1", sceneId: "scene-chill"))
        #expect(steps == [.removeActionSet(homeId: "home-1", sceneId: "scene-chill")])
    }

    @Test func removeActionSetRejectsMissingScene() {
        #expect(error {
            _ = try self.resolve(.removeActionSet(homeId: "home-1", sceneId: "scene-x"))
        } == .objectMissing("No scene scene-x."))
    }

    @Test func executeActionSetResolvesTheScene() throws {
        let steps = try resolve(.executeActionSet(homeId: "home-1", sceneId: "scene-chill"))
        #expect(steps == [.executeActionSet(homeId: "home-1", sceneId: "scene-chill")])
    }

    @Test func executeActionSetRejectsAnEmptyActionSet() {
        var view = fixtureView()
        view.homes[0].scenes.append(DeviceHomeView.Scene(id: "scene-empty", name: "Empty"))
        #expect(error {
            _ = try self.resolve(.executeActionSet(homeId: "home-1", sceneId: "scene-empty"), view: view)
        }?.isInvalidOperation == true)
    }

    @Test func executeActionSetRejectsMissingScene() {
        #expect(error {
            _ = try self.resolve(.executeActionSet(homeId: "home-1", sceneId: "scene-x"))
        } == .objectMissing("No scene scene-x."))
    }

    // MARK: Service groups

    @Test func addServiceGroupRejectsDuplicateName() throws {
        let steps = try resolve(.addServiceGroup(homeId: "home-1", name: "Media", serviceIds: []))
        #expect(steps == [.addServiceGroup(homeId: "home-1", name: "Media", serviceIds: [])])
        #expect(error {
            _ = try self.resolve(.addServiceGroup(homeId: "home-1", name: "everything", serviceIds: []))
        } == .duplicateName("Home already has a service group named “everything”."))
    }

    @Test func addServiceGroupRejectsUnknownService() {
        #expect(error {
            _ = try self.resolve(.addServiceGroup(homeId: "home-1", name: "Media", serviceIds: ["svc-nope"]))
        } == .objectMissing("No service svc-nope in “Townhouse”."))
    }

    @Test func setServiceGroupMembersResolvesServices() throws {
        let steps = try resolve(.setServiceGroupMembers(
            homeId: "home-1", groupId: "group-all",
            addServiceIds: ["svc-light-b"], removeServiceIds: ["svc-light-a"]
        ))
        #expect(steps == [.updateServiceGroupMembers(
            homeId: "home-1", groupId: "group-all",
            addServiceIds: ["svc-light-b"], removeServiceIds: ["svc-light-a"]
        )])
    }

    @Test func setServiceGroupMembersRejectsRemovingANonMember() {
        #expect(error {
            _ = try self.resolve(.setServiceGroupMembers(
                homeId: "home-1", groupId: "group-all",
                addServiceIds: [], removeServiceIds: ["svc-light-b"]
            ))
        } == .objectMissing("Group “Everything” does not contain service svc-light-b."))
    }

    @Test func setServiceGroupMembersRejectsUnknownService() {
        #expect(error {
            _ = try self.resolve(.setServiceGroupMembers(
                homeId: "home-1", groupId: "group-all",
                addServiceIds: ["svc-x"], removeServiceIds: []
            ))
        }?.isInvalidOperation == true)
    }

    @Test func removeServiceGroupResolvesTheGroup() throws {
        let steps = try resolve(.removeServiceGroup(homeId: "home-1", groupId: "group-all"))
        #expect(steps == [.removeServiceGroup(homeId: "home-1", groupId: "group-all")])
        #expect(error { _ = try self.resolve(.removeServiceGroup(homeId: "home-1", groupId: "group-x")) }
            == .objectMissing("No service group group-x."))
    }

    @Test func renameServiceGroupResolvesTheGroup() throws {
        let steps = try resolve(.renameServiceGroup(homeId: "home-1", groupId: "group-all", to: "All Lights"))
        #expect(steps == [.renameServiceGroup(homeId: "home-1", groupId: "group-all", to: "All Lights")])
        #expect(error { _ = try self.resolve(.renameServiceGroup(homeId: "home-1", groupId: "group-x", to: "All Lights")) }
            == .objectMissing("No service group group-x."))
    }

    @Test func renameServiceGroupRejectsDuplicateName() throws {
        var view = fixtureView()
        view.homes[0].serviceGroups.append(DeviceHomeView.ServiceGroup(id: "group-two", name: "Media"))
        #expect(error {
            _ = try self.resolve(.renameServiceGroup(homeId: "home-1", groupId: "group-all", to: "media"), view: view)
        } == .duplicateName("Home already has a service group named “media”."))
        // Case-insensitively renaming a group to its own name is legal — the
        // executor's updateName accepts it; nothing here needs to reject.
        let steps = try resolve(.renameServiceGroup(homeId: "home-1", groupId: "group-all", to: "everything"), view: view)
        #expect(steps == [.renameServiceGroup(homeId: "home-1", groupId: "group-all", to: "everything")])
    }

    // MARK: Timer triggers

    @Test func addTimerTriggerConvertsRecurrenceAndResolvesTheScene() throws {
        let steps = try resolve(.addTimerTrigger(
            homeId: "home-1", name: "Good morning",
            fireDate: fireDate, recurrence: ["hour": 7, "minute": 30], sceneId: "scene-chill"
        ))
        guard case .createTimerTrigger(let homeId, let name, let resolvedDate, let recurrence, let sceneId)? = steps.first else {
            Issue.record("Expected one createTimerTrigger step, got \(steps)")
            return
        }
        #expect(homeId == "home-1" && name == "Good morning" && resolvedDate == fireDate)
        #expect(recurrence?.hour == 7 && recurrence?.minute == 30 && recurrence?.year == nil)
        #expect(sceneId == "scene-chill")
    }

    @Test func addTimerTriggerWithoutSceneOrRecurrence() throws {
        let steps = try resolve(.addTimerTrigger(homeId: "home-1", name: "One shot", fireDate: fireDate, recurrence: [:], sceneId: nil))
        guard case .createTimerTrigger(_, _, _, let recurrence, let sceneId)? = steps.first else {
            Issue.record("Expected one createTimerTrigger step, got \(steps)")
            return
        }
        #expect(recurrence == nil && sceneId == nil)
    }

    @Test func addTimerTriggerRejectsFireDateOffTheMinuteBoundary() {
        let offBoundary = fireDate.addingTimeInterval(17)
        #expect(error {
            _ = try self.resolve(.addTimerTrigger(homeId: "home-1", name: "Sloppy", fireDate: offBoundary, recurrence: [:], sceneId: nil))
        }?.isInvalidOperation == true)
    }

    @Test func addTimerTriggerRejectsRecurrenceUnderFiveMinutes() {
        #expect(error {
            _ = try self.resolve(.addTimerTrigger(homeId: "home-1", name: "Nag", fireDate: fireDate, recurrence: ["minute": 2], sceneId: nil))
        }?.isInvalidOperation == true)
    }

    @Test func addTimerTriggerAcceptsFiveMinuteRecurrence() throws {
        // Exactly 5 minutes is the legal minimum — must resolve, not throw.
        let steps = try resolve(.addTimerTrigger(homeId: "home-1", name: "Minimum", fireDate: fireDate, recurrence: ["minute": 5], sceneId: nil))
        guard case .createTimerTrigger(_, _, _, let recurrence, _)? = steps.first else {
            Issue.record("Expected one createTimerTrigger step, got \(steps)")
            return
        }
        #expect(recurrence?.minute == 5)
    }

    @Test func addTimerTriggerRejectsRecurrenceOverFiveWeeks() {
        #expect(error {
            _ = try self.resolve(.addTimerTrigger(homeId: "home-1", name: "Yearly", fireDate: fireDate, recurrence: ["year": 1], sceneId: nil))
        }?.isInvalidOperation == true)
        // Five weeks exactly is the legal maximum.
        let weekly = try? resolve(.addTimerTrigger(homeId: "home-1", name: "Five weeks", fireDate: fireDate, recurrence: ["day": 35], sceneId: nil))
        #expect(weekly?.count == 1)
    }

    @Test func addTimerTriggerRejectsUnknownRecurrenceComponent() {
        #expect(error {
            _ = try self.resolve(.addTimerTrigger(homeId: "home-1", name: "Odd", fireDate: fireDate, recurrence: ["fortnight": 1], sceneId: nil))
        }?.isInvalidOperation == true)
    }

    @Test func addTimerTriggerRejectsDriftedScene() {
        #expect(error {
            _ = try self.resolve(.addTimerTrigger(homeId: "home-1", name: "Good morning", fireDate: fireDate, recurrence: [:], sceneId: "scene-x"))
        } == .objectMissing("No scene scene-x."))
    }

    // MARK: Event triggers

    @Test func addEventTriggerPicksTheNumberSpecialization() throws {
        let steps = try resolve(.addEventTrigger(
            homeId: "home-1", name: "Bright",
            events: [.characteristic(accessoryId: "acc-light-a", characteristic: "Brightness", value: .int(10))],
            endEvents: [], executeOnce: false,
            sceneId: nil
        ))
        #expect(steps == [.createEventTrigger(
            homeId: "home-1", name: "Bright",
            events: [.characteristic(id: "char-brightness-a", type: "Brightness", value: .number(.int(10)))],
            endEvents: [], executeOnce: false,
            sceneId: nil
        )])
    }

    @Test func addEventTriggerPicksTheStringSpecialization() throws {
        let steps = try resolve(.addEventTrigger(
            homeId: "home-1", name: "Track",
            events: [.characteristic(accessoryId: "acc-lamp-b", characteristic: "TrackName", value: .string("Radiohead"))],
            endEvents: [], executeOnce: false,
            sceneId: nil
        ))
        guard case .createEventTrigger(_, _, let events, _, _, _)? = steps.first, events.count == 1 else {
            Issue.record("Expected one createEventTrigger step, got \(steps)")
            return
        }
        #expect(events[0] == .characteristic(id: "char-track-b", type: "TrackName", value: .string("Radiohead")))
    }

    @Test func addEventTriggerPicksTheNSNullSpecializationForAnyChange() throws {
        let steps = try resolve(.addEventTrigger(
            homeId: "home-1", name: "Any motion",
            events: [.characteristic(accessoryId: "acc-light-a", characteristic: "Brightness", value: nil)],
            endEvents: [], executeOnce: false,
            sceneId: nil
        ))
        #expect(steps == [.createEventTrigger(
            homeId: "home-1", name: "Any motion",
            events: [.characteristic(id: "char-brightness-a", type: "Brightness", value: .anyChange)],
            endEvents: [], executeOnce: false,
            sceneId: nil
        )])
    }

    @Test func addEventTriggerBuildsPresenceEvents() throws {
        let steps = try resolve(.addEventTrigger(
            homeId: "home-1", name: "Arriving",
            events: [.presence(atHome: true)], endEvents: [], executeOnce: false, sceneId: nil
        ))
        #expect(steps == [.createEventTrigger(
            homeId: "home-1", name: "Arriving", events: [.presence(atHome: true)],
            endEvents: [], executeOnce: false, sceneId: nil
        )])
    }

    @Test func addEventTriggerRejectsMixedEventKinds() {
        #expect(error {
            _ = try self.resolve(.addEventTrigger(
                homeId: "home-1", name: "Mixed",
                events: [
                    .presence(atHome: true),
                    .characteristic(accessoryId: "acc-light-a", characteristic: "On", value: .bool(true)),
                ],
                endEvents: [], executeOnce: false,
                sceneId: nil
            ))
        }?.isInvalidOperation == true)
    }

    @Test func addEventTriggerRejectsAStringOnANumberCharacteristic() {
        #expect(error {
            _ = try self.resolve(.addEventTrigger(
                homeId: "home-1", name: "Wrong kind",
                events: [.characteristic(accessoryId: "acc-lamp-b", characteristic: "Volume", value: .string("loud"))],
                endEvents: [], executeOnce: false,
                sceneId: nil
            ))
        }?.isInvalidOperation == true)
    }

    @Test func addEventTriggerRejectsUnknownCharacteristic() {
        #expect(error {
            _ = try self.resolve(.addEventTrigger(
                homeId: "home-1", name: "Ghost",
                events: [.characteristic(accessoryId: "acc-light-a", characteristic: "Hue", value: nil)],
                endEvents: [], executeOnce: false,
                sceneId: nil
            ))
        } == .objectMissing("Accessory “Light A” has no characteristic Hue."))
    }

    // MARK: Event-trigger updates

    @Test func updateEventTriggerSwapsEventsAndResolvesByFriendlyName() throws {
        let steps = try resolve(.updateEventTrigger(
            homeId: "home-1", triggerId: "trigger-event",
            events: [.characteristic(accessoryId: "acc-light-a", characteristic: "Brightness", value: .int(30))],
            endEvents: nil, recurrences: nil, executeOnce: nil, sceneId: nil
        ))
        #expect(steps == [.updateEventTrigger(
            homeId: "home-1", triggerId: "trigger-event",
            events: [.characteristic(id: "char-brightness-a", type: "Brightness", value: .number(.int(30)))],
            endEvents: nil, recurrences: nil, executeOnce: nil, sceneId: nil
        )])
    }

    @Test func updateEventTriggerDerivesThePredicateFromPresenceEvents() throws {
        // The predicate is never a free-form input: presence events imply the
        // presence predicate, exactly like creation (the executor derives it).
        let steps = try resolve(.updateEventTrigger(
            homeId: "home-1", triggerId: "trigger-event",
            events: [.presence(atHome: false)],
            endEvents: nil, recurrences: nil, executeOnce: nil, sceneId: nil
        ))
        #expect(steps == [.updateEventTrigger(
            homeId: "home-1", triggerId: "trigger-event",
            events: [.presence(atHome: false)],
            endEvents: nil, recurrences: nil, executeOnce: nil, sceneId: nil
        )])
    }

    @Test func updateEventTriggerCarriesExecuteOnceAndScene() throws {
        let steps = try resolve(.updateEventTrigger(
            homeId: "home-1", triggerId: "trigger-event",
            events: [.presence(atHome: true)],
            endEvents: nil, recurrences: [["weekday": 2]], executeOnce: true, sceneId: "scene-chill"
        ))
        guard case .updateEventTrigger(_, _, _, _, let recurrences, let executeOnce, let sceneId)? = steps.first else {
            Issue.record("Expected one updateEventTrigger step, got \(steps)")
            return
        }
        #expect(executeOnce == true)
        #expect(sceneId == "scene-chill")
        #expect(recurrences?.count == 1 && recurrences?[0].weekday == 2)
    }

    @Test func updateEventTriggerRejectsTimerTriggers() {
        #expect(error {
            _ = try self.resolve(.updateEventTrigger(
                homeId: "home-1", triggerId: "trigger-timer",
                events: [.presence(atHome: true)],
                endEvents: nil, recurrences: nil, executeOnce: nil, sceneId: nil
            ))
        }?.isInvalidOperation == true)
    }

    @Test func updateEventTriggerRejectsMissingTrigger() {
        #expect(error {
            _ = try self.resolve(.updateEventTrigger(
                homeId: "home-1", triggerId: "trigger-x",
                events: [.presence(atHome: true)],
                endEvents: nil, recurrences: nil, executeOnce: nil, sceneId: nil
            ))
        } == .objectMissing("No trigger trigger-x."))
    }

    @Test func updateEventTriggerRejectsMissingSceneReference() {
        #expect(error {
            _ = try self.resolve(.updateEventTrigger(
                homeId: "home-1", triggerId: "trigger-event",
                events: [.presence(atHome: true)],
                endEvents: nil, recurrences: nil, executeOnce: nil, sceneId: "scene-x"
            ))
        } == .objectMissing("No scene scene-x."))
    }

    @Test func updateEventTriggerRejectsNonWeekdayRecurrences() {
        #expect(error {
            _ = try self.resolve(.updateEventTrigger(
                homeId: "home-1", triggerId: "trigger-event",
                events: [.presence(atHome: true)],
                endEvents: nil, recurrences: [["hour": 2]], executeOnce: nil, sceneId: nil
            ))
        }?.isInvalidOperation == true)
    }

    @Test func addEventTriggerCarriesEndEventsAndExecuteOnce() throws {
        let steps = try resolve(.addEventTrigger(
            homeId: "home-1", name: "Pulse",
            events: [.characteristic(accessoryId: "acc-light-a", characteristic: "On", value: .bool(true))],
            endEvents: [.characteristic(accessoryId: "acc-light-a", characteristic: "On", value: .bool(false))],
            executeOnce: true, sceneId: nil
        ))
        #expect(steps == [.createEventTrigger(
            homeId: "home-1", name: "Pulse",
            events: [.characteristic(id: "char-on-a", type: "On", value: .number(.bool(true)))],
            endEvents: [.characteristic(id: "char-on-a", type: "On", value: .number(.bool(false)))],
            executeOnce: true, sceneId: nil
        )])
    }

    // MARK: Trigger state and deletion

    @Test func setTriggerEnabledResolvesTheTrigger() throws {
        // A disabled trigger WITH a registered action set resolves to the
        // plain enable step — the arm approval.
        let armed = DeviceHomeView.Trigger(
            id: "trigger-quiet", name: "Quiet", isEnabled: false,
            timerFireDate: fireDate, timerRecurrence: [:], linkedSceneIds: ["scene-chill"]
        )
        var view = fixtureView()
        view.homes[0].triggers.append(armed)
        let steps = try resolve(.setTriggerEnabled(homeId: "home-1", triggerId: "trigger-quiet", enabled: true), view: view)
        #expect(steps == [.setTriggerEnabled(homeId: "home-1", triggerId: "trigger-quiet", enabled: true)])

        // Disabling never needs an action set.
        #expect(try resolve(.setTriggerEnabled(homeId: "home-1", triggerId: "trigger-event", enabled: false))
            == [.setTriggerEnabled(homeId: "home-1", triggerId: "trigger-event", enabled: false)])

        #expect(error {
            _ = try self.resolve(.setTriggerEnabled(homeId: "home-1", triggerId: "trigger-x", enabled: true))
        } == .objectMissing("No trigger trigger-x."))
    }

    @Test func enablingAScenelessTriggerIsRejectedWithAnActionableError() {
        // Device law (HMError 26 on the QA run): HomeKit refuses to enable a
        // trigger with no registered action sets. The resolver says so before
        // any device call instead of failing the approval with a raw error.
        #expect(error {
            _ = try self.resolve(.setTriggerEnabled(homeId: "home-1", triggerId: "trigger-event", enabled: true))
        }?.isInvalidOperation == true)
    }

    @Test func updateTimerTriggerResolvesRemoveAndReAddWithStateRestore() throws {
        // The fixture's timer trigger is enabled and linked to "scene-chill":
        // the replace step must carry both forward — restoring an approved
        // arming is the only arm a write ever performs.
        let steps = try resolve(.updateTimerTrigger(
            homeId: "home-1", triggerId: "trigger-timer",
            fireDate: fireDate, recurrence: ["hour": 8]
        ))
        guard case .replaceTimerTrigger(let homeId, let triggerId, let resolvedDate, let recurrence, let wasEnabled, let sceneIds)? = steps.first else {
            Issue.record("Expected one replaceTimerTrigger step, got \(steps)")
            return
        }
        #expect(homeId == "home-1" && triggerId == "trigger-timer" && resolvedDate == fireDate)
        #expect(recurrence?.hour == 8)
        #expect(wasEnabled == true)
        #expect(sceneIds == ["scene-chill"])
    }

    @Test func updateTimerTriggerOnADisabledTriggerStaysDisabled() throws {
        let disabled = DeviceHomeView.Trigger(
            id: "trigger-quiet", name: "Quiet", isEnabled: false,
            timerFireDate: fireDate, timerRecurrence: [:], linkedSceneIds: []
        )
        var view = fixtureView()
        view.homes[0].triggers.append(disabled)
        let steps = try resolve(
            .updateTimerTrigger(homeId: "home-1", triggerId: "trigger-quiet", fireDate: fireDate, recurrence: [:]),
            view: view
        )
        guard case .replaceTimerTrigger(_, _, _, _, let wasEnabled, _)? = steps.first else {
            Issue.record("Expected one replaceTimerTrigger step, got \(steps)")
            return
        }
        #expect(wasEnabled == false)
    }

    @Test func updateTimerTriggerRejectsEventTriggers() {
        #expect(error {
            _ = try self.resolve(.updateTimerTrigger(homeId: "home-1", triggerId: "trigger-event", fireDate: fireDate, recurrence: [:]))
        }?.isInvalidOperation == true)
    }

    @Test func updateTimerTriggerRejectsDriftedAndInvalidSchedules() {
        #expect(error {
            _ = try self.resolve(.updateTimerTrigger(homeId: "home-1", triggerId: "trigger-x", fireDate: fireDate, recurrence: [:]))
        } == .objectMissing("No trigger trigger-x."))
        #expect(error {
            _ = try self.resolve(.updateTimerTrigger(
                homeId: "home-1", triggerId: "trigger-timer",
                fireDate: fireDate.addingTimeInterval(5), recurrence: [:]
            ))
        }?.isInvalidOperation == true)
    }

    @Test func removeTriggerResolvesTheTrigger() throws {
        let steps = try resolve(.removeTrigger(homeId: "home-1", triggerId: "trigger-timer"))
        #expect(steps == [.removeTrigger(homeId: "home-1", triggerId: "trigger-timer")])
        #expect(error { _ = try self.resolve(.removeTrigger(homeId: "home-1", triggerId: "trigger-x")) }
            == .objectMissing("No trigger trigger-x."))
    }

    // MARK: - Accessory lifecycle

    /// The five accessory operations resolve against the fixture view —
    /// steps echo the resolved ids, and missing objects reject with the
    /// typed error naming the accessory.
    @Test func accessoryOpsResolveToSteps() throws {
        #expect(try resolve(.renameAccessory(homeId: "home-1", accessoryId: "acc-light-a", to: "Kitchen Lamp"))
            == [.renameAccessory(homeId: "home-1", accessoryId: "acc-light-a", to: "Kitchen Lamp")])
        #expect(try resolve(.assignAccessoryToRoom(homeId: "home-1", accessoryId: "acc-light-a", roomId: "room-office"))
            == [.assignAccessoryToRoom(homeId: "home-1", accessoryId: "acc-light-a", roomId: "room-office")])
        #expect(try resolve(.unblockAccessory(homeId: "home-1", accessoryId: "acc-light-a"))
            == [.unblockAccessory(homeId: "home-1", accessoryId: "acc-light-a")])
        #expect(try resolve(.removeAccessory(homeId: "home-1", accessoryId: "acc-light-a"))
            == [.removeAccessory(homeId: "home-1", accessoryId: "acc-light-a")])
        #expect(try resolve(.identifyAccessory(homeId: "home-1", accessoryId: "acc-light-a"))
            == [.identifyAccessory(homeId: "home-1", accessoryId: "acc-light-a")])
        #expect(error {
            _ = try self.resolve(.renameAccessory(homeId: "home-1", accessoryId: "acc-nowhere", to: "Ghost"))
        } == .objectMissing("No accessory acc-nowhere in home “Townhouse”."))
        #expect(error {
            _ = try self.resolve(.assignAccessoryToRoom(homeId: "home-1", accessoryId: "acc-light-a", roomId: "room-nowhere"))
        }?.isInvalidOperation == false) // the room lookup fails, not a constraint check
        #expect(error {
            _ = try self.resolve(.assignAccessoryToRoom(homeId: "home-1", accessoryId: "acc-light-a", roomId: "room-nowhere"))
        }?.message.contains("No room room-nowhere") == true)
    }

    /// Device law: HomeKit refuses names that do not start and end with a
    /// letter or digit (HMError 60 felled the QA rename to “Office Lights
    /// (QA)”). Resolution rejects them where the agent gets a typed error
    /// naming the accessory, the proposed name, and the offending
    /// characters — and accepts names HomeKit itself would.
    @Test func accessoryRenameRejectsNamesHomeKitRefuses() throws {
        #expect(error {
            _ = try self.resolve(.renameAccessory(homeId: "home-1", accessoryId: "acc-light-a", to: "Office Lights (QA)"))
        }?.message == "Accessory “Light A” cannot be renamed to “Office Lights (QA)”: names must end with a letter or digit, and “)” is neither.")
        #expect(error {
            _ = try self.resolve(.renameAccessory(homeId: "home-1", accessoryId: "acc-light-a", to: "—Office Lights"))
        }?.message.contains("names must start with a letter or digit") == true)
        #expect(error {
            _ = try self.resolve(.renameAccessory(homeId: "home-1", accessoryId: "acc-light-a", to: String(repeating: "A", count: 65)))
        }?.message.contains("at most 64 characters") == true)

        // Interior punctuation and international letters survive — HomeKit
        // accepts every name the anchor rule lets through.
        #expect(try resolve(.renameAccessory(homeId: "home-1", accessoryId: "acc-light-a", to: "Office (QA) Lights"))
            == [.renameAccessory(homeId: "home-1", accessoryId: "acc-light-a", to: "Office (QA) Lights")])
        #expect(try resolve(.renameAccessory(homeId: "home-1", accessoryId: "acc-light-a", to: "Salón"))
            == [.renameAccessory(homeId: "home-1", accessoryId: "acc-light-a", to: "Salón")])
    }

    /// The name rules themselves, as one table: the anchor and length
    /// constraints reject; apostrophes, digits, interior punctuation, and
    /// non-ASCII letters pass.
    @Test func nameViolationCoversTheHomeKitNameRules() {
        #expect(DeviceWriteResolver.nameViolation("") == "names must not be empty")
        #expect(DeviceWriteResolver.nameViolation("   ") == "names must not be empty")
        #expect(DeviceWriteResolver.nameViolation(String(repeating: "A", count: 65))?.contains("at most 64") == true)
        #expect(DeviceWriteResolver.nameViolation(String(repeating: "A", count: 64)) == nil)
        #expect(DeviceWriteResolver.nameViolation("-Office Lights")?.contains("must start with") == true)
        #expect(DeviceWriteResolver.nameViolation("Office 🏠")?.contains("must end with") == true)
        #expect(DeviceWriteResolver.nameViolation("Office (QA) Lights") == nil)
        #expect(DeviceWriteResolver.nameViolation("John's Office") == nil)
        #expect(DeviceWriteResolver.nameViolation("Room 2") == nil)
        #expect(DeviceWriteResolver.nameViolation("Salón") == nil)
    }

    /// Device law: identifying means flashing the Identify characteristic;
    /// an accessory known not to support it rejects at resolution with the
    /// typed reason, while unknown capability data stays permissive.
    @Test func identifyRejectsKnownUnsupportedAccessory() throws {
        var view = fixtureView()
        view.homes[0].accessories[
            view.homes[0].accessories.firstIndex { $0.id == "acc-light-a" }!
        ].supportsIdentify = false
        #expect(error {
            _ = try self.resolve(.identifyAccessory(homeId: "home-1", accessoryId: "acc-light-a"), view: view)
        }?.isInvalidOperation == true)

        view.homes[0].accessories[
            view.homes[0].accessories.firstIndex { $0.id == "acc-light-a" }!
        ].supportsIdentify = true
        #expect(try resolve(.identifyAccessory(homeId: "home-1", accessoryId: "acc-light-a"), view: view)
            == [.identifyAccessory(homeId: "home-1", accessoryId: "acc-light-a")])
    }
}

extension HomeKitWriteError {
    /// Pattern-match helper for cases whose detail message is not asserted.
    var isInvalidOperation: Bool {
        if case .invalidOperation = self { return true }
        return false
    }
}
