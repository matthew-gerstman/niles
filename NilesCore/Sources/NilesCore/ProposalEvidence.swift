import Foundation

/// Builds read-back evidence from the home graph AFTER an approved proposal
/// executes (spec: "read-back evidence after execution"). Pure over the
/// graph: the store snapshots the post-execution state and hands it here,
/// and every planned change yields one entry whose `confirmed` flag is
/// computed from what the graph actually shows.
public enum ProposalEvidenceCollector {

    /// One evidence entry per operation, in execution order.
    public static func collect(operations: [HomeKitOperation], graph: HomeGraph) -> [ProposalEvidence] {
        operations.map { collect(operation: $0, graph: graph) }
    }

    private static func collect(operation: HomeKitOperation, graph: HomeGraph) -> ProposalEvidence {
        switch operation {
        case .addRoom(_, let name):
            let room = graph.homes.flatMap(\.rooms).first { $0.name == name }
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
                    observed: "Zone \(zoneId) not found after execution",
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

        case .addActionSet(_, let name, _):
            let scene = graph.homes.flatMap(\.scenes).first { $0.name == name }
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

        case .addServiceGroup(_, let name):
            let group = graph.homes.flatMap(\.serviceGroups).first { $0.name == name }
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

        case .removeServiceGroup(_, let groupId):
            let stillPresent = contains(groupId, in: graph.homes.flatMap(\.serviceGroups).map(\.id))
            return ProposalEvidence(
                claim: "Service group \(groupId) is deleted",
                observed: stillPresent ? "Group still present — delete did not take effect" : "No service group with id \(groupId) remains",
                confirmed: !stillPresent
            )
        }
    }

    /// Ids are globally unique across homes, so a flat membership check is exact.
    private static func contains(_ id: String, in ids: [String]) -> Bool {
        ids.contains(id)
    }

    private static func roomName(of roomId: String, graph: HomeGraph) -> String {
        graph.homes.flatMap(\.rooms).first(where: { $0.id == roomId })?.name ?? roomId
    }
}
