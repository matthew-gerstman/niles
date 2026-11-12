import Foundation

extension ProposalPlanner {
    // MARK: - Accessories

    static func renameAccessory(accessoryId: String, name: String, graph: HomeGraph) throws -> Plan {
        let (home, accessory) = try self.accessory(id: accessoryId, in: graph)
        let trimmed = try requiredHomeKitName(name, kind: "accessory", subject: "Accessory “\(accessory.name)”")
        if accessory.name.caseInsensitiveCompare(trimmed) == .orderedSame {
            throw PlannerError.noChange("accessory “\(accessory.name)” is already named “\(trimmed)”.")
        }
        return Plan(
            tool: "rename_accessory",
            title: "Rename accessory “\(accessory.name)”",
            summary: "Rename accessory “\(accessory.name)” to “\(trimmed)”",
            isDestructive: false,
            operations: [.renameAccessory(homeId: home.id, accessoryId: accessory.id, to: trimmed)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .accessory, id: accessory.id, name: accessory.name),
                op: .rename,
                before: accessory.name,
                after: trimmed
            )],
            card: [ProposalCardLine(.plain, "Accessory “\(accessory.name)” → “\(trimmed)”")]
        )
    }

    /// Spec (accessory lifecycle): identify flashes or beeps the physical
    /// device — harmless but physical, so the card says so. Accessories
    /// without an Identify characteristic cannot be identified: when the
    /// graph carries the capability data a `false` rejects staging with the
    /// typed reason; missing data degrades to a permissive note, the same
    /// shape the characteristic capability check uses.
    static func identifyAccessory(accessoryId: String, graph: HomeGraph) throws -> Plan {
        let (home, accessory) = try self.accessory(id: accessoryId, in: graph)
        var card: [ProposalCardLine] = [
            ProposalCardLine(.add, "Accessory “\(accessory.name)” · identified (flash/beep)"),
        ]
        switch accessory.supportsIdentify {
        case .some(false):
            throw PlannerError.invalidInput(
                "Accessory “\(accessory.name)” does not support identify — it has no Identify characteristic."
            )
        case .some(true):
            break
        case nil:
            card.append(ProposalCardLine(
                .note,
                "⚠ Could not verify identify support — “\(accessory.name)”'s capability data is unavailable; approval may still fail at execution."
            ))
        }
        return Plan(
            tool: "identify_accessory",
            title: "Identify accessory “\(accessory.name)”",
            summary: "Identify accessory “\(accessory.name)” (flash/beep)",
            isDestructive: false,
            operations: [.identifyAccessory(homeId: home.id, accessoryId: accessory.id)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .accessory, id: accessory.id, name: accessory.name),
                op: .update,
                before: "idle",
                after: "flash/beep on approval"
            )],
            card: card
        )
    }

    static func assignAccessoryToRoom(accessoryId: String, roomId: String, graph: HomeGraph) throws -> Plan {
        let (home, accessory) = try self.accessory(id: accessoryId, in: graph)
        guard let room = home.rooms.first(where: { $0.id == roomId }) else {
            throw PlannerError.unknownRoom(roomId)
        }
        let currentRoom = home.rooms.first { $0.accessories.contains { $0.id == accessory.id } }
        if currentRoom?.id == room.id {
            throw PlannerError.noChange(
                "accessory “\(accessory.name)” is already in “\(room.name)”."
            )
        }
        let from = currentRoom.map { "“\($0.name)”" } ?? "no room"
        return Plan(
            tool: "assign_accessory_to_room",
            title: "Move accessory “\(accessory.name)” to \(room.name)",
            summary: "Move accessory “\(accessory.name)” from \(from) to “\(room.name)”",
            isDestructive: false,
            operations: [.assignAccessoryToRoom(homeId: home.id, accessoryId: accessory.id, roomId: room.id)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .accessory, id: accessory.id, name: accessory.name),
                op: .move,
                before: currentRoom?.name,
                after: room.name
            )],
            card: [ProposalCardLine(
                .plain,
                "Accessory “\(accessory.name)” · \(from) → “\(room.name)”"
            )]
        )
    }

    /// A security block is HomeKit holding the accessory back (a paused or
    /// misbehaving bridge device); unblocking lets it run again. Blocked
    /// state is not in the graph (the read-depth flags are a separate
    /// group), so staging checks existence only and the card says what
    /// unblocking means.
    static func unblockAccessory(accessoryId: String, graph: HomeGraph) throws -> Plan {
        let (home, accessory) = try self.accessory(id: accessoryId, in: graph)
        return Plan(
            tool: "unblock_accessory",
            title: "Unblock accessory “\(accessory.name)”",
            summary: "Unblock accessory “\(accessory.name)”",
            isDestructive: false,
            operations: [.unblockAccessory(homeId: home.id, accessoryId: accessory.id)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .accessory, id: accessory.id, name: accessory.name),
                op: .update,
                before: "blocked",
                after: "unblocked"
            )],
            card: [ProposalCardLine(
                .add,
                "Accessory “\(accessory.name)” · unblocked — HomeKit resumes controlling it"
            )]
        )
    }

    /// Spec (destructive severity): the card lists every scene, service
    /// group, and trigger that references the accessory — its actions die
    /// with it, its services leave their groups, its characteristics stop
    /// firing triggers — and where it lands: nowhere, the accessory leaves
    /// the home entirely.
    static func removeAccessory(accessoryId: String, graph: HomeGraph) throws -> Plan {
        let (home, accessory) = try self.accessory(id: accessoryId, in: graph)
        let currentRoom = home.rooms.first { $0.accessories.contains { $0.id == accessory.id } }

        let referencingScenes = home.scenes.filter { scene in
            scene.actions.contains { $0.accessoryId == accessory.id }
        }
        let referencingGroups = home.serviceGroups.filter { group in
            group.services.contains { $0.accessoryId == accessory.id }
        }
        let referencingTriggers = home.triggers.filter { trigger in
            guard case .event(let current) = trigger.detail else { return false }
            return current.events.contains { $0.accessoryId == accessory.id }
        }

        var card: [ProposalCardLine] = [
            ProposalCardLine(.remove, "Accessory “\(accessory.name)” · deleted"),
        ]
        if let currentRoom {
            card.append(ProposalCardLine(.plain, "It leaves room “\(currentRoom.name)” and the home entirely."))
        }
        for scene in referencingScenes {
            card.append(ProposalCardLine(
                .note,
                "⚠ Scene “\(scene.name)” loses every action it performs on this accessory."
            ))
        }
        for group in referencingGroups {
            card.append(ProposalCardLine(
                .note,
                "⚠ Service group “\(group.name)” loses this accessory's services."
            ))
        }
        for trigger in referencingTriggers {
            card.append(ProposalCardLine(
                .note,
                "⚠ Trigger “\(trigger.name)” fires on this accessory's characteristics and will stop working."
            ))
        }
        if referencingScenes.isEmpty && referencingGroups.isEmpty && referencingTriggers.isEmpty {
            card.append(ProposalCardLine(.plain, "Nothing references this accessory."))
        }

        return Plan(
            tool: "remove_accessory",
            title: "Delete accessory “\(accessory.name)”",
            summary: "Delete accessory “\(accessory.name)”",
            isDestructive: true,
            operations: [.removeAccessory(homeId: home.id, accessoryId: accessory.id)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .accessory, id: accessory.id, name: accessory.name),
                op: .delete,
                before: accessory.name,
                after: nil
            )],
            card: card
        )
    }
}
