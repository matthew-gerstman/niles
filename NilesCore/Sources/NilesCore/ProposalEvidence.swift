import Foundation

/// Builds read-back evidence from the home graph AFTER an approved proposal
/// executes (spec: "read-back evidence after execution"). Pure over the
/// graph: the store snapshots the post-execution state and hands it here,
/// and every planned change yields one entry whose `confirmed` flag is
/// computed from what the graph actually shows.
public enum ProposalEvidenceCollector {

    /// One evidence entry per operation, in execution order. `createdIds`
    /// carries the id `perform` returned for each operation (nil for pure
    /// mutations or operations that never ran): a created room, scene,
    /// service group, or trigger is then matched by id, so a same-named
    /// pre-existing object cannot false-confirm a creation. Name matching
    /// is only the fallback when no created id is known.
    public static func collect(
        operations: [HomeKitOperation], createdIds: [String?], graph: HomeGraph
    ) -> [ProposalEvidence] {
        let ids = createdIds.count == operations.count
            ? createdIds
            : Array(repeating: nil as String?, count: operations.count)
        return zip(operations, ids).enumerated().map { batchIndex, pair in
            collect(
                operation: pair.offset, createdId: pair.element,
                batch: operations, batchIndex: batchIndex, graph: graph
            )
        }
    }

    private static func collect(
        operation: HomeKitOperation, createdId: String?,
        batch: [HomeKitOperation], batchIndex: Int, graph: HomeGraph
    ) -> ProposalEvidence {
        switch operation {
        case .addRoom(_, let name):
            let rooms = graph.homes.flatMap(\.rooms)
            let room = createdId.flatMap { id in rooms.first { $0.id == id } } ?? rooms.first { $0.name == name }
            let noun = room.map { $0.accessories.count == 1 ? "accessory" : "accessories" } ?? ""
            return ProposalEvidence(
                claim: "Room “\(name)” exists",
                observed: room.map { "Room “\($0.name)” contains \($0.accessories.count) \(noun)" }
                    ?? "Room “\(name)” not found after execution",
                confirmed: room != nil
            )

        case .renameRoom(_, let roomId, let to):
            let room = graph.homes.flatMap(\.rooms).first { $0.id == roomId }
            return ProposalEvidence(
                claim: "Room \(roomId) is named “\(to)”",
                observed: room.map { "Room now named “\($0.name)”" }
                    ?? "Room \(roomId) not found after execution",
                confirmed: room?.name == to
            )

        case .removeRoom(_, let roomId):
            let stillPresent = contains(roomId, in: graph.homes.flatMap(\.rooms).map(\.id))
            return ProposalEvidence(
                claim: "Room \(roomId) is deleted",
                observed: stillPresent ? "Room still present — delete did not take effect" : "No room with id \(roomId) remains",
                confirmed: !stillPresent
            )

        case .setZoneRooms(_, let zoneId, let addRoomIds, let removeRoomIds):
            guard let zone = graph.homes.flatMap(\.zones).first(where: { $0.id == zoneId }) else {
                return ProposalEvidence(
                    claim: "Zone \(zoneId) membership updated",
                    observed: Self.missingZoneObservation(zoneId: zoneId, batch: batch, batchIndex: batchIndex),
                    confirmed: false
                )
            }
            let memberNames = zone.roomIds.map { roomName(of: $0, graph: graph) }
            var observed = "Zone “\(zone.name)” now contains \(zone.roomIds.count) room\(zone.roomIds.count == 1 ? "" : "s")"
            if let firstAdded = addRoomIds.first {
                observed += ", including “\(roomName(of: firstAdded, graph: graph))”"
            }
            if !memberNames.isEmpty {
                observed += ": \(memberNames.joined(separator: ", "))"
            }
            let confirmed = addRoomIds.allSatisfy(zone.roomIds.contains)
                && removeRoomIds.allSatisfy { !zone.roomIds.contains($0) }
            return ProposalEvidence(claim: "Zone \(zoneId) membership updated", observed: observed, confirmed: confirmed)

        case .createZone(_, let name):
            let zones = graph.homes.flatMap(\.zones)
            let zone = createdId.flatMap { id in zones.first { $0.id == id } } ?? zones.first { $0.name == name }
            if zone == nil, let createdId, Self.removedLaterInBatch(createdId, after: batchIndex, in: batch) {
                return ProposalEvidence(
                    claim: "Zone \(createdId) exists",
                    observed: Self.missingZoneObservation(zoneId: createdId, batch: batch, batchIndex: batchIndex),
                    confirmed: false
                )
            }
            return ProposalEvidence(
                claim: "Zone “\(name)” exists",
                observed: zone.map {
                    "Zone “\($0.name)” contains \($0.roomIds.count) room\($0.roomIds.count == 1 ? "" : "s")"
                } ?? "Zone “\(name)” not found after execution",
                confirmed: zone != nil
            )

        case .renameZone(_, let zoneId, let to):
            let zone = graph.homes.flatMap(\.zones).first { $0.id == zoneId }
            if zone == nil, Self.removedLaterInBatch(zoneId, after: batchIndex, in: batch) {
                return ProposalEvidence(
                    claim: "Zone \(zoneId) is named “\(to)”",
                    observed: Self.missingZoneObservation(zoneId: zoneId, batch: batch, batchIndex: batchIndex),
                    confirmed: false
                )
            }
            return ProposalEvidence(
                claim: "Zone \(zoneId) is named “\(to)”",
                observed: zone.map { "Zone now named “\($0.name)”" }
                    ?? "Zone \(zoneId) not found after execution",
                confirmed: zone?.name == to
            )

        case .removeZone(_, let zoneId):
            let stillPresent = contains(zoneId, in: graph.homes.flatMap(\.zones).map(\.id))
            let roomsStillThere = graph.homes.flatMap(\.rooms).count
            return ProposalEvidence(
                claim: "Zone \(zoneId) is deleted, rooms preserved",
                observed: stillPresent
                    ? "Zone still present — delete did not take effect"
                    : "No zone with id \(zoneId) remains; \(roomsStillThere) room\(roomsStillThere == 1 ? "" : "s") untouched",
                confirmed: !stillPresent
            )

        case .addActionSet(_, let name, _):
            let scenes = graph.homes.flatMap(\.scenes)
            let scene = createdId.flatMap { id in scenes.first { $0.id == id } } ?? scenes.first { $0.name == name }
            let noun = scene.map { $0.actions.count == 1 ? "action" : "actions" } ?? ""
            return ProposalEvidence(
                claim: "Scene “\(name)” exists",
                observed: scene.map { "Scene “\($0.name)” holds \($0.actions.count) \(noun)" }
                    ?? "Scene “\(name)” not found after execution",
                confirmed: scene != nil
            )

        case .setSceneActions(_, let sceneId, let add, let remove):
            guard let scene = graph.homes.flatMap(\.scenes).first(where: { $0.id == sceneId }) else {
                return ProposalEvidence(
                    claim: "Scene \(sceneId) actions updated",
                    observed: "Scene \(sceneId) not found after execution",
                    confirmed: false
                )
            }
            let current = scene.actions.map(SceneActionKey.init(action:))
            let confirmed = add.allSatisfy { spec in current.contains(SceneActionKey(spec: spec)) }
                && remove.allSatisfy { key in !current.contains(key) }
            let noun = scene.actions.count == 1 ? "action" : "actions"
            return ProposalEvidence(
                claim: "Scene \(sceneId) actions updated",
                observed: "Scene “\(scene.name)” now holds \(scene.actions.count) \(noun)",
                confirmed: confirmed
            )

        case .renameActionSet(_, let sceneId, let to):
            let scene = graph.homes.flatMap(\.scenes).first { $0.id == sceneId }
            return ProposalEvidence(
                claim: "Scene \(sceneId) is named “\(to)”",
                observed: scene.map { "Scene now named “\($0.name)”" }
                    ?? "Scene \(sceneId) not found after execution",
                confirmed: scene?.name == to
            )

        case .removeActionSet(_, let sceneId):
            let stillPresent = contains(sceneId, in: graph.homes.flatMap(\.scenes).map(\.id))
            let danglingLinks = graph.homes.flatMap(\.triggers).filter { $0.linkedSceneIds.contains(sceneId) }
            var observed = stillPresent
                ? "Scene still present — delete did not take effect"
                : "No scene with id \(sceneId) remains"
            if !danglingLinks.isEmpty {
                let names = danglingLinks.map(\.name).joined(separator: ", ")
                observed += "; triggers still referencing it: \(names)"
            }
            return ProposalEvidence(
                claim: "Scene \(sceneId) is deleted",
                observed: observed,
                confirmed: !stillPresent
            )

        case .executeActionSet(_, let sceneId):
            // Execution has no graph-observable signature until
            // lastExecutionDate lands (read-depth group); the honest
            // read-back is that the scene exists and HomeKit accepted the
            // run — not a claim the devices moved.
            guard let scene = graph.homes.flatMap(\.scenes).first(where: { $0.id == sceneId }) else {
                return ProposalEvidence(
                    claim: "Scene \(sceneId) ran",
                    observed: "Scene \(sceneId) not found after execution",
                    confirmed: false
                )
            }
            let noun = scene.actions.count == 1 ? "action" : "actions"
            return ProposalEvidence(
                claim: "Scene \(sceneId) ran",
                observed: "HomeKit accepted the run — scene “\(scene.name)” is present with \(scene.actions.count) \(noun)",
                confirmed: true
            )

        case .addServiceGroup(_, let name):
            let groups = graph.homes.flatMap(\.serviceGroups)
            let group = createdId.flatMap { id in groups.first { $0.id == id } } ?? groups.first { $0.name == name }
            let noun = group.map { $0.services.count == 1 ? "service" : "services" } ?? ""
            return ProposalEvidence(
                claim: "Service group “\(name)” exists",
                observed: group.map { "Group “\($0.name)” holds \($0.services.count) \(noun)" }
                    ?? "Service group “\(name)” not found after execution",
                confirmed: group != nil
            )

        case .setServiceGroupMembers(_, let groupId, let addServiceIds, let removeServiceIds):
            guard let group = graph.homes.flatMap(\.serviceGroups).first(where: { $0.id == groupId }) else {
                return ProposalEvidence(
                    claim: "Service group \(groupId) membership updated",
                    observed: "Service group \(groupId) not found after execution",
                    confirmed: false
                )
            }
            let current = group.services.map(\.id)
            let confirmed = addServiceIds.allSatisfy(current.contains)
                && removeServiceIds.allSatisfy { !current.contains($0) }
            var observed = "Group “\(group.name)” now holds \(group.services.count) service\(group.services.count == 1 ? "" : "s")"
            let names = group.services.map(\.name)
            if !names.isEmpty {
                observed += ": \(names.joined(separator: ", "))"
            }
            return ProposalEvidence(
                claim: "Service group \(groupId) membership updated",
                observed: observed,
                confirmed: confirmed
            )

        case .renameServiceGroup(_, let groupId, let to):
            let group = graph.homes.flatMap(\.serviceGroups).first { $0.id == groupId }
            return ProposalEvidence(
                claim: "Service group \(groupId) is named “\(to)”",
                observed: group.map { "Group now named “\($0.name)”" }
                    ?? "Service group \(groupId) not found after execution",
                confirmed: group?.name == to
            )

        case .removeServiceGroup(_, let groupId):
            let stillPresent = contains(groupId, in: graph.homes.flatMap(\.serviceGroups).map(\.id))
            return ProposalEvidence(
                claim: "Service group \(groupId) is deleted",
                observed: stillPresent ? "Group still present — delete did not take effect" : "No service group with id \(groupId) remains",
                confirmed: !stillPresent
            )

        case .addTimerTrigger(_, let name, let fireDate, let recurrence, let sceneId):
            return triggerCreatedEvidence(
                claim: "Timer trigger “\(name)” exists (disabled)",
                name: name, createdId: createdId, sceneId: sceneId, graph: graph
            )

        case .addEventTrigger(_, let name, _, _, _, let sceneId):
            return triggerCreatedEvidence(
                claim: "Event trigger “\(name)” exists (disabled)",
                name: name, createdId: createdId, sceneId: sceneId, graph: graph
            )

        case .setTriggerEnabled(_, let triggerId, let enabled):
            return triggerStateEvidence(triggerId: triggerId, expected: enabled, graph: graph)

        case .updateTimerTrigger(_, let triggerId, let fireDate, let recurrence):
            guard let trigger = graph.homes.flatMap(\.triggers).first(where: { $0.id == triggerId }) else {
                return ProposalEvidence(
                    claim: "Timer trigger \(triggerId) schedule updated",
                    observed: "Trigger \(triggerId) not found after execution",
                    confirmed: false
                )
            }
            guard case .timer(let observedDate, let observedRecurrence) = trigger.detail else {
                return ProposalEvidence(
                    claim: "Timer trigger \(triggerId) schedule updated",
                    observed: "Trigger “\(trigger.name)” is no longer a timer trigger",
                    confirmed: false
                )
            }
            let confirmed = observedDate == fireDate && observedRecurrence == recurrence
            return ProposalEvidence(
                claim: "Timer trigger \(triggerId) schedule updated",
                observed: confirmed
                    ? "Trigger “\(trigger.name)” now fires \(ISOTimestamps.render(observedDate))"
                    : "Trigger “\(trigger.name)” shows a different schedule after execution",
                confirmed: confirmed
            )

        case .updateEventTrigger(
            _, let triggerId, let events, _, _, _, let sceneId
        ):
            // Read-back for a declarative edit: the trigger exists, is still
            // an event trigger, and now watches exactly the proposed events
            // — matched by canonical identity (name or UUID), the one shared
            // rule — and runs the proposed scene when one was passed.
            guard let home = graph.homes.first(where: { $0.triggers.contains { $0.id == triggerId } }),
                let trigger = home.triggers.first(where: { $0.id == triggerId })
            else {
                return ProposalEvidence(
                    claim: "Event trigger \(triggerId) events updated",
                    observed: "Trigger \(triggerId) not found after execution",
                    confirmed: false
                )
            }
            guard case .event(let currentEvents, _) = trigger.detail else {
                return ProposalEvidence(
                    claim: "Event trigger \(triggerId) events updated",
                    observed: "Trigger “\(trigger.name)” is no longer an event trigger",
                    confirmed: false
                )
            }
            let currentKeys = Set(currentEvents.map { $0.canonicalKey(in: home) })
            let eventsConfirmed = events.allSatisfy { currentKeys.contains($0.canonicalKey(in: home)) }
            let sceneConfirmed = sceneId.map { trigger.linkedSceneIds.contains($0) } ?? true
            let confirmed = eventsConfirmed && sceneConfirmed
            let state = trigger.isEnabled ? "enabled" : "disabled"
            return ProposalEvidence(
                claim: "Event trigger \(triggerId) events updated",
                observed: confirmed
                    ? "Trigger “\(trigger.name)” now watches \(currentEvents.count) event\(currentEvents.count == 1 ? "" : "s") and stays \(state)"
                    : "Trigger “\(trigger.name)” shows different events after execution",
                confirmed: confirmed
            )

        case .removeTrigger(_, let triggerId):
            let stillPresent = contains(triggerId, in: graph.homes.flatMap(\.triggers).map(\.id))
            return ProposalEvidence(
                claim: "Trigger \(triggerId) is deleted",
                observed: stillPresent ? "Trigger still present — delete did not take effect" : "No trigger with id \(triggerId) remains",
                confirmed: !stillPresent
            )

        case .renameAccessory(_, let accessoryId, let to):
            let accessory = graph.homes.flatMap(\.rooms).flatMap(\.accessories).first { $0.id == accessoryId }
            return ProposalEvidence(
                claim: "Accessory \(accessoryId) is named “\(to)”",
                observed: accessory.map { "Accessory now named “\($0.name)”" }
                    ?? "Accessory \(accessoryId) not found after execution",
                confirmed: accessory?.name == to
            )

        case .identifyAccessory(_, let accessoryId):
            let stillPresent = contains(
                accessoryId, in: graph.homes.flatMap(\.rooms).flatMap(\.accessories).map(\.id)
            )
            return ProposalEvidence(
                claim: "Accessory \(accessoryId) was identified",
                observed: stillPresent
                    ? "Accessory still present — identify (flash/beep) has no graph-observable effect"
                    : "Accessory \(accessoryId) not found after execution",
                confirmed: stillPresent
            )

        case .assignAccessoryToRoom(_, let accessoryId, let roomId):
            let accessory = graph.homes.flatMap(\.rooms).flatMap(\.accessories).first { $0.id == accessoryId }
            let room = graph.homes.flatMap(\.rooms).first { $0.accessories.contains { $0.id == accessoryId } }
            let confirmed = room?.id == roomId
            return ProposalEvidence(
                claim: "Accessory \(accessoryId) is in room \(roomId)",
                observed: confirmed
                    ? "Accessory “\(accessory?.name ?? accessoryId)” now sits in room “\(room?.name ?? roomId)”"
                    : room.map { "Accessory “\(accessory?.name ?? accessoryId)” sits in room “\($0.name)”, not \(roomId)" }
                        ?? "Accessory \(accessoryId) not found after execution",
                confirmed: confirmed
            )

        case .unblockAccessory(_, let accessoryId):
            let stillPresent = contains(
                accessoryId, in: graph.homes.flatMap(\.rooms).flatMap(\.accessories).map(\.id)
            )
            return ProposalEvidence(
                claim: "Accessory \(accessoryId) was unblocked",
                observed: stillPresent
                    ? "Accessory still present — blocked state is not graph-observable"
                    : "Accessory \(accessoryId) not found after execution",
                confirmed: stillPresent
            )

        case .removeAccessory(_, let accessoryId):
            let stillPresent = contains(
                accessoryId, in: graph.homes.flatMap(\.rooms).flatMap(\.accessories).map(\.id)
            )
            return ProposalEvidence(
                claim: "Accessory \(accessoryId) is deleted",
                observed: stillPresent ? "Accessory still present — delete did not take effect" : "No accessory with id \(accessoryId) remains",
                confirmed: !stillPresent
            )

        case .writeCharacteristic(_, let action):
            let accessory = graph.homes.flatMap(\.rooms).flatMap(\.accessories).first { $0.id == action.accessoryId }
            let ref = accessory?.characteristic(action.characteristic, service: action.service)
            let label = ref?.name ?? action.characteristic
            let name = accessory?.name ?? action.accessoryId
            let confirmed = ref?.valueDescription == action.value.rendered
            return ProposalEvidence(
                claim: "\(name) \(label) is \(action.value.rendered)",
                observed: ref.map {
                    "\(name) \(label) now reads \($0.valueDescription ?? "no value")"
                } ?? "Accessory \(action.accessoryId) not found after execution",
                confirmed: confirmed
            )
        }
    }

    /// Read-back for a created trigger: it must exist, still be disabled
    /// (the locked rule — creation never arms), and any referenced scene
    /// must exist in the same graph.
    private static func triggerCreatedEvidence(
        claim: String, name: String, createdId: String?, sceneId: String?, graph: HomeGraph
    ) -> ProposalEvidence {
        let triggers = graph.homes.flatMap(\.triggers)
        let trigger = createdId.flatMap { id in triggers.first { $0.id == id } } ?? triggers.first { $0.name == name }
        let scenePresent = sceneId.map { id in
            graph.homes.flatMap(\.scenes).contains { $0.id == id }
        } ?? true
        let confirmed = trigger != nil && trigger?.isEnabled == false && scenePresent
        var observed: String
        if let trigger {
            observed = trigger.isEnabled
                ? "Trigger “\(trigger.name)” exists but is ENABLED — creation must never arm"
                : "Trigger “\(trigger.name)” exists and is disabled"
        } else {
            observed = "Trigger “\(name)” not found after execution"
        }
        if trigger != nil, let sceneId, !scenePresent {
            observed += "; scene \(sceneId) not found"
        }
        return ProposalEvidence(claim: claim, observed: observed, confirmed: confirmed)
    }

    private static func triggerStateEvidence(
        triggerId: String, expected: Bool, graph: HomeGraph
    ) -> ProposalEvidence {
        guard let trigger = graph.homes.flatMap(\.triggers).first(where: { $0.id == triggerId }) else {
            return ProposalEvidence(
                claim: "Trigger \(triggerId) is \(expected ? "enabled" : "disabled")",
                observed: "Trigger \(triggerId) not found after execution",
                confirmed: false
            )
        }
        let confirmed = trigger.isEnabled == expected
        return ProposalEvidence(
            claim: "Trigger \(triggerId) is \(expected ? "enabled" : "disabled")",
            observed: "Trigger “\(trigger.name)” is now \(trigger.isEnabled ? "enabled" : "disabled")",
            confirmed: confirmed
        )
    }

    /// Ids are globally unique across homes, so a flat membership check is exact.
    private static func contains(_ id: String, in ids: [String]) -> Bool {
        ids.contains(id)
    }

    private static func roomName(of roomId: String, graph: HomeGraph) -> String {
        graph.homes.flatMap(\.rooms).first(where: { $0.id == roomId })?.name ?? roomId
    }

    /// The honest "zone is gone from the read-back" observation. A later
    /// operation in the same approval batch can delete the zone an earlier
    /// operation just updated or created — the write executed first, but
    /// the final graph no longer contains the zone to read back. That
    /// ordering artifact must not read as "execution failed". (Device QA F3.)
    private static func missingZoneObservation(
        zoneId: String, batch: [HomeKitOperation], batchIndex: Int
    ) -> String {
        if removedLaterInBatch(zoneId, after: batchIndex, in: batch) {
            return "Zone \(zoneId) was deleted by a later operation in this batch — the write executed before the delete, so the final zone no longer exists to read back"
        }
        return "Zone \(zoneId) not found after execution"
    }

    /// True when an operation after `index` in the same approval batch
    /// removes the object with this id. Only deletions matter here: they
    /// are the one later change that makes an object unreadable.
    private static func removedLaterInBatch(
        _ objectId: String, after index: Int, in batch: [HomeKitOperation]
    ) -> Bool {
        batch.dropFirst(index + 1).contains { operation in
            switch operation {
            case .removeZone(_, let id): id == objectId
            default: false
            }
        }
    }
}
