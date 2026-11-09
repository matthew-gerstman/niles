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
            sceneId: nil
        ), view: liveShapedView())
        #expect(steps == [.createEventTrigger(
            homeId: "home-live", name: "Evening",
            events: [.characteristic(
                id: "char-brightness-live", type: "00000008-0000-1000-8000-0026BB765291", value: .number(.int(30))
            )],
            sceneId: nil
        )])
    }

    // MARK: Service groups

    @Test func addServiceGroupRejectsDuplicateName() throws {
        let steps = try resolve(.addServiceGroup(homeId: "home-1", name: "Media"))
        #expect(steps == [.addServiceGroup(homeId: "home-1", name: "Media")])
        #expect(error {
            _ = try self.resolve(.addServiceGroup(homeId: "home-1", name: "everything"))
        } == .duplicateName("Home already has a service group named “everything”."))
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
            sceneId: nil
        ))
        #expect(steps == [.createEventTrigger(
            homeId: "home-1", name: "Bright",
            events: [.characteristic(id: "char-brightness-a", type: "Brightness", value: .number(.int(10)))],
            sceneId: nil
        )])
    }

    @Test func addEventTriggerPicksTheStringSpecialization() throws {
        let steps = try resolve(.addEventTrigger(
            homeId: "home-1", name: "Track",
            events: [.characteristic(accessoryId: "acc-lamp-b", characteristic: "TrackName", value: .string("Radiohead"))],
            sceneId: nil
        ))
        guard case .createEventTrigger(_, _, let events, _)? = steps.first, events.count == 1 else {
            Issue.record("Expected one createEventTrigger step, got \(steps)")
            return
        }
        #expect(events[0] == .characteristic(id: "char-track-b", type: "TrackName", value: .string("Radiohead")))
    }

    @Test func addEventTriggerPicksTheNSNullSpecializationForAnyChange() throws {
        let steps = try resolve(.addEventTrigger(
            homeId: "home-1", name: "Any motion",
            events: [.characteristic(accessoryId: "acc-light-a", characteristic: "Brightness", value: nil)],
            sceneId: nil
        ))
        #expect(steps == [.createEventTrigger(
            homeId: "home-1", name: "Any motion",
            events: [.characteristic(id: "char-brightness-a", type: "Brightness", value: .anyChange)],
            sceneId: nil
        )])
    }

    @Test func addEventTriggerBuildsPresenceEvents() throws {
        let steps = try resolve(.addEventTrigger(
            homeId: "home-1", name: "Arriving",
            events: [.presence(atHome: true)], sceneId: nil
        ))
        #expect(steps == [.createEventTrigger(
            homeId: "home-1", name: "Arriving", events: [.presence(atHome: true)], sceneId: nil
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
                sceneId: nil
            ))
        }?.isInvalidOperation == true)
    }

    @Test func addEventTriggerRejectsAStringOnANumberCharacteristic() {
        #expect(error {
            _ = try self.resolve(.addEventTrigger(
                homeId: "home-1", name: "Wrong kind",
                events: [.characteristic(accessoryId: "acc-lamp-b", characteristic: "Volume", value: .string("loud"))],
                sceneId: nil
            ))
        }?.isInvalidOperation == true)
    }

    @Test func addEventTriggerRejectsUnknownCharacteristic() {
        #expect(error {
            _ = try self.resolve(.addEventTrigger(
                homeId: "home-1", name: "Ghost",
                events: [.characteristic(accessoryId: "acc-light-a", characteristic: "Hue", value: nil)],
                sceneId: nil
            ))
        } == .objectMissing("Accessory “Light A” has no characteristic Hue."))
    }

    // MARK: Trigger state and deletion

    @Test func setTriggerEnabledResolvesTheTrigger() throws {
        let steps = try resolve(.setTriggerEnabled(homeId: "home-1", triggerId: "trigger-event", enabled: true))
        #expect(steps == [.setTriggerEnabled(homeId: "home-1", triggerId: "trigger-event", enabled: true)])
        #expect(error {
            _ = try self.resolve(.setTriggerEnabled(homeId: "home-1", triggerId: "trigger-x", enabled: true))
        } == .objectMissing("No trigger trigger-x."))
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
}

extension HomeKitWriteError {
    /// Pattern-match helper for cases whose detail message is not asserted.
    var isInvalidOperation: Bool {
        if case .invalidOperation = self { return true }
        return false
    }
}
