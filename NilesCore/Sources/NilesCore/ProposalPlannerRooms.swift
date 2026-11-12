import Foundation

extension ProposalPlanner {
    // MARK: - Rooms

    static func createRoom(homeId: String, name: String, graph: HomeGraph) throws -> Plan {
        let trimmed = try requiredHomeKitName(name, kind: "room")
        let home = try self.home(id: homeId, in: graph)
        try rejectDuplicate(kind: "room", name: trimmed, in: home.rooms.map(\.name), homeName: home.name)
        return Plan(
            tool: "create_room",
            title: "Create room “\(trimmed)”",
            summary: "Create room “\(trimmed)” in “\(home.name)”",
            isDestructive: false,
            operations: [.addRoom(homeId: home.id, name: trimmed)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .room, id: "", name: trimmed),
                op: .create,
                before: nil,
                after: trimmed
            )],
            card: [ProposalCardLine(.add, "Room “\(trimmed)” · created")]
        )
    }

    static func renameRoom(roomId: String, name: String, graph: HomeGraph) throws -> Plan {
        let (home, room) = try self.room(id: roomId, in: graph)
        let trimmed = try requiredHomeKitName(name, kind: "room", subject: "Room “\(room.name)”")
        if room.name == trimmed {
            throw PlannerError.noChange("room “\(room.name)” is already named “\(trimmed)”.")
        }
        return Plan(
            tool: "rename_room",
            title: "Rename room “\(room.name)”",
            summary: "Rename room “\(room.name)” to “\(trimmed)”",
            isDestructive: false,
            operations: [.renameRoom(homeId: home.id, roomId: room.id, to: trimmed)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .room, id: room.id, name: room.name),
                op: .rename,
                before: room.name,
                after: trimmed
            )],
            card: [ProposalCardLine(.plain, "Room “\(room.name)” → “\(trimmed)”")]
        )
    }

    static func deleteRoom(roomId: String, graph: HomeGraph) throws -> Plan {
        let (home, room) = try self.room(id: roomId, in: graph)
        let displaced = room.accessories.count

        var card: [ProposalCardLine] = [ProposalCardLine(.remove, "Room “\(room.name)” · deleted")]
        if displaced > 0 {
            // Spec risk (shared-database blast radius): HomeKit reassigns the
            // deleted room's accessories to the default room. The card says so.
            let noun = displaced == 1 ? "accessory" : "accessories"
            card.append(ProposalCardLine(.note, "⚠ \(displaced) \(noun) will move to the default room"))
        }
        card.append(ProposalCardLine(
            .plain,
            "Visible immediately to Siri, the Home app, and every automation that references this room."
        ))

        return Plan(
            tool: "delete_room",
            title: "Delete room “\(room.name)”",
            summary: "Delete room “\(room.name)”",
            isDestructive: true,
            operations: [.removeRoom(homeId: home.id, roomId: room.id)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .room, id: room.id, name: room.name),
                op: .delete,
                before: room.name,
                after: nil
            )],
            card: card
        )
    }
}
