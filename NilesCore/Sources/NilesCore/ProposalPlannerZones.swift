import Foundation

extension ProposalPlanner {
    // MARK: - Zones

    static func setZoneRooms(zoneId: String, roomIds: [String], graph: HomeGraph) throws -> Plan {
        let (home, zone) = try self.zone(id: zoneId, in: graph)

        // Deduplicate while preserving the agent's order.
        var seen = Set<String>()
        let target: [String] = roomIds.filter { seen.insert($0).inserted }
        for roomId in target where !home.rooms.contains(where: { $0.id == roomId }) {
            throw PlannerError.unknownRoom(roomId)
        }

        let current = zone.roomIds
        let additions = target.filter { !current.contains($0) }
        let removals = current.filter { !target.contains($0) }
        if additions.isEmpty && removals.isEmpty {
            throw PlannerError.noChange("zone “\(zone.name)” already contains exactly these rooms.")
        }

        let zoneRef = ProposalObjectRef(kind: .zone, id: zone.id, name: zone.name)
        let entries: [ProposalDiffEntry] =
            additions.map { roomId in
                ProposalDiffEntry(
                    object: zoneRef, op: .addMembers,
                    before: nil, after: Self.room(id: roomId, in: home)?.name ?? roomId
                )
            }
            + removals.map { roomId in
                ProposalDiffEntry(
                    object: zoneRef, op: .removeMembers,
                    before: Self.room(id: roomId, in: home)?.name ?? roomId, after: nil
                )
            }

        var card: [ProposalCardLine] =
            additions.map { roomId in
                ProposalCardLine(.add, "“\(zone.name)” · add room “\(Self.room(id: roomId, in: home)?.name ?? roomId)”")
            }
            + removals.map { roomId in
                ProposalCardLine(.remove, "“\(zone.name)” · remove room “\(Self.room(id: roomId, in: home)?.name ?? roomId)”")
            }
        // The spec's worked example: agents re-send the full membership, and
        // the card must show that the other rooms simply stay.
        if removals.isEmpty {
            let staying = current.filter { !additions.contains($0) }.compactMap { Self.room(id: $0, in: home)?.name }
            if !staying.isEmpty {
                let names = staying.joined(separator: ", ")
                let verb = staying.count == 1 ? "stays" : "stay"
                card.append(ProposalCardLine(.plain, "No rooms removed — \(names) \(verb)."))
            }
        }

        return Plan(
            tool: "set_zone_rooms",
            title: Self.zoneTitle(zoneName: zone.name, additions: additions, removals: removals, home: home),
            summary: Self.zoneSummary(
                zoneName: zone.name, additions: additions, removals: removals, home: home
            ),
            isDestructive: false,
            operations: [.setZoneRooms(homeId: home.id, zoneId: zone.id, addRoomIds: additions, removeRoomIds: removals)],
            entries: entries,
            card: card
        )
    }

    static func zoneTitle(zoneName: String, additions: [String], removals: [String], home: HomeGraph.Home) -> String {
        if additions.count == 1, removals.isEmpty {
            return "Move \(roomName(id: additions[0], home: home)) into \(zoneName)"
        }
        if removals.count == 1, additions.isEmpty {
            return "Remove \(roomName(id: removals[0], home: home)) from \(zoneName)"
        }
        return "Update zone “\(zoneName)”"
    }

    static func zoneSummary(zoneName: String, additions: [String], removals: [String], home: HomeGraph.Home) -> String {
        if additions.count == 1, removals.isEmpty {
            return "Add room “\(roomName(id: additions[0], home: home))” to zone “\(zoneName)”"
        }
        if removals.count == 1, additions.isEmpty {
            return "Remove room “\(roomName(id: removals[0], home: home))” from zone “\(zoneName)”"
        }
        return "Update zone “\(zoneName)” membership (\(additions.count) added, \(removals.count) removed)"
    }

    static func createZone(homeId: String, name: String, graph: HomeGraph) throws -> Plan {
        let trimmed = try requiredHomeKitName(name, kind: "zone")
        let home = try self.home(id: homeId, in: graph)
        try rejectDuplicate(kind: "zone", name: trimmed, in: home.zones.map(\.name), homeName: home.name)
        return Plan(
            tool: "create_zone",
            title: "Create zone “\(trimmed)”",
            summary: "Create zone “\(trimmed)” in “\(home.name)”",
            isDestructive: false,
            operations: [.createZone(homeId: home.id, name: trimmed)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .zone, id: "", name: trimmed),
                op: .create,
                before: nil,
                after: trimmed
            )],
            card: [ProposalCardLine(.add, "Zone “\(trimmed)” · created (empty — add rooms with set_zone_rooms)")]
        )
    }

    static func renameZone(zoneId: String, name: String, graph: HomeGraph) throws -> Plan {
        let (home, zone) = try self.zone(id: zoneId, in: graph)
        let trimmed = try requiredHomeKitName(name, kind: "zone", subject: "Zone “\(zone.name)”")
        if zone.name.caseInsensitiveCompare(trimmed) == .orderedSame {
            throw PlannerError.noChange("zone “\(zone.name)” is already named “\(trimmed)”.")
        }
        // Zone names are unique within a home; the new name cannot collide
        // with another zone — this one included.
        let otherZones = home.zones.filter { $0.id != zone.id }
        try rejectDuplicate(kind: "zone", name: trimmed, in: otherZones.map(\.name), homeName: home.name)
        return Plan(
            tool: "rename_zone",
            title: "Rename zone “\(zone.name)”",
            summary: "Rename zone “\(zone.name)” to “\(trimmed)”",
            isDestructive: false,
            operations: [.renameZone(homeId: home.id, zoneId: zone.id, to: trimmed)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .zone, id: zone.id, name: zone.name),
                op: .rename,
                before: zone.name,
                after: trimmed
            )],
            card: [ProposalCardLine(.plain, "Zone “\(zone.name)” → “\(trimmed)”")]
        )
    }

    /// Spec (destructive severity): the card shows how many rooms the zone
    /// grouped, and states plainly that the rooms survive — removing a zone
    /// dissolves only the grouping, never the rooms.
    static func deleteZone(zoneId: String, graph: HomeGraph) throws -> Plan {
        let (home, zone) = try self.zone(id: zoneId, in: graph)
        let memberNames = zone.roomIds.compactMap { room(id: $0, in: home)?.name }

        var card: [ProposalCardLine] = [ProposalCardLine(.remove, "Zone “\(zone.name)” · deleted")]
        if memberNames.isEmpty {
            card.append(ProposalCardLine(.plain, "The zone has no rooms."))
        } else {
            let roomNoun = memberNames.count == 1 ? "room" : "rooms"
            card.append(ProposalCardLine(
                .plain,
                "It grouped \(memberNames.count) \(roomNoun): \(memberNames.joined(separator: ", "))."
            ))
        }
        card.append(ProposalCardLine(
            .plain,
            "The rooms survive untouched — deleting a zone removes only the grouping."
        ))

        return Plan(
            tool: "delete_zone",
            title: "Delete zone “\(zone.name)”",
            summary: "Delete zone “\(zone.name)”",
            isDestructive: true,
            operations: [.removeZone(homeId: home.id, zoneId: zone.id)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .zone, id: zone.id, name: zone.name),
                op: .delete,
                before: zone.name,
                after: nil
            )],
            card: card
        )
    }
}
