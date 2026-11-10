import Foundation

/// The members an undo restores into an object its revert re-creates. A
/// re-created room, zone, or group gets a fresh id at revert time, so the
/// restore is applied against that id after the re-create runs.
public enum MemberRestore: Sendable, Equatable {
    /// Accessory ids moved back into the re-created room.
    case roomAccessories(homeId: String, accessoryIds: [String])
    /// Room ids added back to the re-created zone.
    case zoneRooms(homeId: String, roomIds: [String])
    /// Service ids added back to the re-created group.
    case groupServices(homeId: String, serviceIds: [String])

    /// The operations that move the members into the object the revert
    /// re-created; `createdId` is the fresh id the re-create returned.
    func operations(createdId: String) -> [HomeKitOperation] {
        switch self {
        case .roomAccessories(let homeId, let accessoryIds):
            accessoryIds.map { .assignAccessoryToRoom(homeId: homeId, accessoryId: $0, roomId: createdId) }
        case .zoneRooms(let homeId, let roomIds):
            [.setZoneRooms(homeId: homeId, zoneId: createdId, addRoomIds: roomIds, removeRoomIds: [])]
        case .groupServices(let homeId, let serviceIds):
            [.setServiceGroupMembers(homeId: homeId, groupId: createdId, addServiceIds: serviceIds, removeServiceIds: [])]
        }
    }
}

/// The paired revert of one executed proposal, captured at execution time:
/// the concrete operations that rewind it, the membership its re-create
/// restores, the prior names a re-create must find free again, and the
/// executed operations plus created ids — what the undo conflict-check
/// re-runs against the current home.
public struct RevertPlan: Sendable, Equatable {
    public enum RecreatedKind: String, Sendable {
        case room, zone, scene, serviceGroup
    }

    struct RecreatedName: Sendable, Equatable {
        let kind: RecreatedKind
        let name: String
    }

    /// Operations that rewind the change — none reference runtime ids; a
    /// re-created object's fresh id resolves while the revert executes.
    public let operations: [HomeKitOperation]
    /// Members moved back into the object this revert re-creates, if any.
    let memberRestore: MemberRestore?
    /// Prior names a re-create must not collide with at undo time — HomeKit
    /// rejects duplicates, and re-taking a name means the world moved.
    let recreatedNames: [RecreatedName]
    /// Where execution left the displaced members (accessory id -> room id),
    /// so an undo never yanks an accessory out of a room some later change
    /// chose.
    let memberLocations: [String: String]
    /// The operations that executed and the ids their creates returned —
    /// the conflict check re-runs their read-back against the current graph.
    let executed: [HomeKitOperation]
    let createdIds: [String?]

    init(
        operations: [HomeKitOperation],
        memberRestore: MemberRestore?,
        recreatedNames: [RecreatedName],
        memberLocations: [String: String],
        executed: [HomeKitOperation],
        createdIds: [String?]
    ) {
        self.operations = operations
        self.memberRestore = memberRestore
        self.recreatedNames = recreatedNames
        self.memberLocations = memberLocations
        self.executed = executed
        self.createdIds = createdIds
    }

    /// The divergences that block this revert: the executed change's own
    /// read-back checks re-run against the current graph (values still equal
    /// the recorded post-state, membership unchanged), plus each re-create's
    /// prior name being free again. Empty is what makes an undo safe.
    public func conflicts(in graph: HomeGraph) -> [ProposalEvidence] {
        var divergences = ProposalEvidenceCollector.collect(
            operations: executed, createdIds: createdIds, graph: graph
        ).filter { !$0.confirmed }
        for name in recreatedNames where Self.exists(named: name.name, kind: name.kind, in: graph) {
            divergences.append(ProposalEvidence(
                claim: "No \(name.kind.rawValue) named “\(name.name)” exists",
                observed: "A \(name.kind.rawValue) named “\(name.name)” already exists — the name was re-taken",
                confirmed: false
            ))
        }
        let home = graph.homes.first
        for (accessoryId, expectedRoomId) in memberLocations {
            let containingRoom = home?.rooms.first(where: { room in
                room.accessories.contains { $0.id == accessoryId }
            })
            if containingRoom?.id != expectedRoomId {
                divergences.append(ProposalEvidence(
                    claim: "Accessory \(accessoryId) is still in room \(expectedRoomId)",
                    observed: containingRoom.map { "It is now in room \($0.id) (“\($0.name)”)" }
                        ?? "The accessory no longer exists in the home",
                    confirmed: false
                ))
            }
        }
        return divergences
    }

    static func exists(named name: String, kind: RecreatedKind, in graph: HomeGraph) -> Bool {
        let home = graph.homes.first
        let objects: [(String, String)]? = switch kind {
        case .room: home?.rooms.map { ($0.id, $0.name) }
        case .zone: home?.zones.map { ($0.id, $0.name) }
        case .scene: home?.scenes.map { ($0.id, $0.name) }
        case .serviceGroup: home?.serviceGroups.map { ($0.id, $0.name) }
        }
        return objects?.contains { $0.1.caseInsensitiveCompare(name) == .orderedSame } ?? false
    }
}

/// Builds the paired revert for executed operations against the graphs as
/// they stood before and after execution. Pure — the store captures both
/// snapshots and hands them in.
enum RevertPlanBuilder {
    /// The revert for one executed proposal, or nil when it cannot be
    /// honestly undone: any operation without a meaningful inverse (scene
    /// execution, identify, unblock, accessory removal — a device cannot be
    /// re-paired from here) makes the whole proposal unrevertable, because a
    /// partial undo would be a lie about what was applied.
    static func plan(
        operations: [HomeKitOperation], createdIds: [String?],
        preGraph: HomeGraph, postGraph: HomeGraph
    ) -> RevertPlan? {
        guard operations.count == createdIds.count else { return nil }
        var revertOperations: [HomeKitOperation] = []
        var memberRestore: MemberRestore?
        var recreatedNames: [RevertPlan.RecreatedName] = []
        var memberLocations: [String: String] = [:]
        for (operation, createdId) in zip(operations, createdIds) {
            guard let built = revert(of: operation, createdId: createdId, graph: preGraph, postGraph: postGraph) else {
                return nil
            }
            revertOperations.append(contentsOf: built.operations)
            if let restore = built.memberRestore {
                // What the planner emits today re-creates at most one object
                // per proposal; a second would need positional restores.
                precondition(memberRestore == nil, "A plan re-created more than one object")
                memberRestore = restore
            }
            recreatedNames.append(contentsOf: built.recreatedNames)
            for (accessoryId, roomId) in built.memberLocations {
                memberLocations[accessoryId] = roomId
            }
        }
        return RevertPlan(
            operations: revertOperations,
            memberRestore: memberRestore,
            recreatedNames: recreatedNames,
            memberLocations: memberLocations,
            executed: operations,
            createdIds: createdIds
        )
    }

    private struct BuiltRevert {
        var operations: [HomeKitOperation]
        var memberRestore: MemberRestore?
        var recreatedNames: [RevertPlan.RecreatedName]
        var memberLocations: [String: String] = [:]
    }

    /// The paired revert of one operation against the graph as it was before
    /// execution. `createdId` is what the operation's execution returned —
    /// the id of the object it created, when it created one.
    private static func revert(
        of operation: HomeKitOperation, createdId: String?, graph: HomeGraph, postGraph: HomeGraph
    ) -> BuiltRevert? {
        let home = graph.homes.first
        switch operation {
        // Creates revert to deleting what execution created, by recorded id.
        case .addRoom(let homeId, _):
            guard let id = createdId else { return nil }
            return BuiltRevert(operations: [.removeRoom(homeId: homeId, roomId: id)], memberRestore: nil, recreatedNames: [])
        case .createZone(let homeId, _):
            guard let id = createdId else { return nil }
            return BuiltRevert(operations: [.removeZone(homeId: homeId, zoneId: id)], memberRestore: nil, recreatedNames: [])
        case .addActionSet(let homeId, _, _):
            guard let id = createdId else { return nil }
            return BuiltRevert(operations: [.removeActionSet(homeId: homeId, sceneId: id)], memberRestore: nil, recreatedNames: [])
        case .addServiceGroup(let homeId, _, _):
            guard let id = createdId else { return nil }
            return BuiltRevert(operations: [.removeServiceGroup(homeId: homeId, groupId: id)], memberRestore: nil, recreatedNames: [])
        case .addTimerTrigger(let homeId, _, _, _, _), .addEventTrigger(let homeId, _, _, _, _, _):
            guard let id = createdId else { return nil }
            return BuiltRevert(operations: [.removeTrigger(homeId: homeId, triggerId: id)], memberRestore: nil, recreatedNames: [])

        // Renames revert to renaming back to the prior name.
        case .renameRoom(let homeId, let roomId, _):
            guard let prior = home?.rooms.first(where: { $0.id == roomId })?.name else { return nil }
            return BuiltRevert(operations: [.renameRoom(homeId: homeId, roomId: roomId, to: prior)], memberRestore: nil, recreatedNames: [])
        case .renameZone(let homeId, let zoneId, _):
            guard let prior = home?.zones.first(where: { $0.id == zoneId })?.name else { return nil }
            return BuiltRevert(operations: [.renameZone(homeId: homeId, zoneId: zoneId, to: prior)], memberRestore: nil, recreatedNames: [])
        case .renameActionSet(let homeId, let sceneId, _):
            guard let prior = home?.scenes.first(where: { $0.id == sceneId })?.name else { return nil }
            return BuiltRevert(operations: [.renameActionSet(homeId: homeId, sceneId: sceneId, to: prior)], memberRestore: nil, recreatedNames: [])
        case .renameServiceGroup(let homeId, let groupId, _):
            guard let prior = home?.serviceGroups.first(where: { $0.id == groupId })?.name else { return nil }
            return BuiltRevert(operations: [.renameServiceGroup(homeId: homeId, groupId: groupId, to: prior)], memberRestore: nil, recreatedNames: [])
        case .renameAccessory(let homeId, let accessoryId, _):
            guard let prior = Self.accessories(in: graph).first(where: { $0.id == accessoryId })?.name else { return nil }
            return BuiltRevert(operations: [.renameAccessory(homeId: homeId, accessoryId: accessoryId, to: prior)], memberRestore: nil, recreatedNames: [])

        // Deletes revert to re-creating the object (same name) and
        // restoring its prior membership. The re-created object gets a
        // fresh id at revert time; the restore is applied against it.
        case .removeRoom(let homeId, let roomId):
            guard let room = home?.rooms.first(where: { $0.id == roomId }) else { return nil }
            var built = BuiltRevert(
                operations: [.addRoom(homeId: homeId, name: room.name)],
                memberRestore: .roomAccessories(homeId: homeId, accessoryIds: room.accessories.map(\.id)),
                recreatedNames: [RevertPlan.RecreatedName(kind: .room, name: room.name)]
            )
            // Execution displaced the members to the default room; the
            // conflict check holds them there until the undo lands. Their
            // post-execution location is read from the post-execution graph.
            for accessory in room.accessories {
                if let displaced = postExecutionRoom(of: accessory.id, in: postGraph) {
                    built.memberLocations[accessory.id] = displaced
                }
            }
            return built
        case .removeZone(let homeId, let zoneId):
            guard let zone = home?.zones.first(where: { $0.id == zoneId }) else { return nil }
            return BuiltRevert(
                operations: [.createZone(homeId: homeId, name: zone.name)],
                memberRestore: .zoneRooms(homeId: homeId, roomIds: zone.roomIds),
                recreatedNames: [RevertPlan.RecreatedName(kind: .zone, name: zone.name)]
            )
        case .removeServiceGroup(let homeId, let groupId):
            guard let group = home?.serviceGroups.first(where: { $0.id == groupId }) else { return nil }
            return BuiltRevert(
                operations: [.addServiceGroup(homeId: homeId, name: group.name, serviceIds: [])],
                memberRestore: .groupServices(homeId: homeId, serviceIds: group.services.map(\.id)),
                recreatedNames: [RevertPlan.RecreatedName(kind: .serviceGroup, name: group.name)]
            )
        case .removeTrigger(let homeId, let triggerId):
            guard let trigger = home?.triggers.first(where: { $0.id == triggerId }) else { return nil }
            switch trigger.detail {
            case .timer(let fireDate, let recurrence):
                // A re-created trigger is born disabled (the create/arm
                // firewall); arming it again is its own approval.
                return BuiltRevert(
                    operations: [.addTimerTrigger(
                        homeId: homeId, name: trigger.name, fireDate: fireDate,
                        recurrence: recurrence, sceneId: trigger.linkedSceneIds.first
                    )],
                    memberRestore: nil, recreatedNames: []
                )
            case .event(let events, _):
                guard let specs = Self.eventSpecs(from: events) else { return nil }
                return BuiltRevert(
                    operations: [.addEventTrigger(
                        homeId: homeId, name: trigger.name, events: specs, endEvents: [],
                        executeOnce: false, sceneId: trigger.linkedSceneIds.first
                    )],
                    memberRestore: nil, recreatedNames: []
                )
            case .unknown:
                return nil
            }
        case .removeActionSet(let homeId, let sceneId):
            guard let scene = home?.scenes.first(where: { $0.id == sceneId }),
                  let actions = Self.sceneSpecs(from: scene.actions)
            else { return nil }
            // Trigger links the scene had are not restored — the operation
            // vocabulary links a trigger to a scene only at trigger create
            // or event-trigger update; the revert's evidence shows reality.
            return BuiltRevert(
                operations: [.addActionSet(homeId: homeId, name: scene.name, actions: actions)],
                memberRestore: nil,
                recreatedNames: [RevertPlan.RecreatedName(kind: .scene, name: scene.name)]
            )

        // Membership diffs revert to the opposite diff — the operations
        // carry the already-diffed lists, so the inverse is concrete.
        case .setZoneRooms(let homeId, let zoneId, let addRoomIds, let removeRoomIds):
            return BuiltRevert(
                operations: [.setZoneRooms(
                    homeId: homeId, zoneId: zoneId, addRoomIds: removeRoomIds, removeRoomIds: addRoomIds
                )],
                memberRestore: nil, recreatedNames: []
            )
        case .setServiceGroupMembers(let homeId, let groupId, let addServiceIds, let removeServiceIds):
            return BuiltRevert(
                operations: [.setServiceGroupMembers(
                    homeId: homeId, groupId: groupId,
                    addServiceIds: removeServiceIds, removeServiceIds: addServiceIds
                )],
                memberRestore: nil, recreatedNames: []
            )
        case .setSceneActions(let homeId, let sceneId, let add, let remove):
            guard let scene = home?.scenes.first(where: { $0.id == sceneId }) else { return nil }
            let removedKeys = Set(remove)
            let removedActions = scene.actions.filter { removedKeys.contains(SceneActionKey(action: $0)) }
            guard let removedSpecs = Self.sceneSpecs(from: removedActions), removedSpecs.count == removedActions.count
            else { return nil }
            return BuiltRevert(
                operations: [.setSceneActions(
                    homeId: homeId, sceneId: sceneId,
                    add: removedSpecs, remove: add.map(SceneActionKey.init(spec:))
                )],
                memberRestore: nil, recreatedNames: []
            )

        // Trigger edits revert to rewriting the prior contents; arming
        // state is untouched (the create/arm firewall).
        case .setTriggerEnabled(let homeId, let triggerId, _):
            guard let prior = home?.triggers.first(where: { $0.id == triggerId })?.isEnabled else { return nil }
            return BuiltRevert(
                operations: [.setTriggerEnabled(homeId: homeId, triggerId: triggerId, enabled: prior)],
                memberRestore: nil, recreatedNames: []
            )
        case .updateTimerTrigger(let homeId, let triggerId, _, _):
            guard case .timer(let fireDate, let recurrence)? = home?.triggers
                .first(where: { $0.id == triggerId })?.detail
            else { return nil }
            return BuiltRevert(
                operations: [.updateTimerTrigger(
                    homeId: homeId, triggerId: triggerId, fireDate: fireDate, recurrence: recurrence
                )],
                memberRestore: nil, recreatedNames: []
            )
        case .updateEventTrigger(let homeId, let triggerId, _, _, _, _, _):
            guard let trigger = home?.triggers.first(where: { $0.id == triggerId }),
                  case .event(let events, _) = trigger.detail,
                  let specs = Self.eventSpecs(from: events)
            else { return nil }
            return BuiltRevert(
                operations: [.updateEventTrigger(
                    homeId: homeId, triggerId: triggerId, events: specs, endEvents: nil,
                    recurrences: nil, executeOnce: nil, sceneId: trigger.linkedSceneIds.first
                )],
                memberRestore: nil, recreatedNames: []
            )

        // Writes and assignments revert to the recorded prior state.
        case .writeCharacteristic(let homeId, let action):
            guard let accessory = Self.accessories(in: graph).first(where: { $0.id == action.accessoryId }),
                  let ref = accessory.characteristic(action.characteristic, service: action.service),
                  let rendered = ref.valueDescription
            else { return nil }
            let prior = HomeKitValue(rendered: rendered, format: ref.metadata?.format)
            return BuiltRevert(
                operations: [.writeCharacteristic(homeId: homeId, action: SceneActionSpec(
                    accessoryId: action.accessoryId, service: action.service,
                    characteristic: action.characteristic, value: prior
                ))],
                memberRestore: nil, recreatedNames: []
            )
        case .assignAccessoryToRoom(let homeId, let accessoryId, _):
            guard let priorRoom = postExecutionRoom(of: accessoryId, in: graph) else { return nil }
            return BuiltRevert(
                operations: [.assignAccessoryToRoom(homeId: homeId, accessoryId: accessoryId, roomId: priorRoom)],
                memberRestore: nil, recreatedNames: []
            )

        // No meaningful inverse: a scene run has no observable before, a
        // flash or unblock changes nothing persistent, and a removed
        // accessory's hardware cannot be re-paired from here.
        case .executeActionSet, .identifyAccessory, .unblockAccessory, .removeAccessory:
            return nil
        }
    }

    /// The room containing the accessory in the graph as it stands — used
    /// against the pre-execution graph for an assignment's prior room, and
    /// against the post-execution graph for a deletion's displaced members.
    private static func postExecutionRoom(of accessoryId: String, in graph: HomeGraph) -> String? {
        for room in graph.homes.first?.rooms ?? [] where room.accessories.contains(where: { $0.id == accessoryId }) {
            return room.id
        }
        return nil
    }

    private static func accessories(in graph: HomeGraph) -> [HomeGraph.Accessory] {
        var seen = Set<String>()
        return graph.homes.flatMap(\.rooms).flatMap(\.accessories)
            .filter { seen.insert($0.id).inserted }
    }

    /// Scene actions as the specs a revert would re-add. Values travel as
    /// rendered strings (the read side's one rendering rule); the parse is
    /// faithful for every scene action the graph can carry today.
    private static func sceneSpecs(from actions: [HomeGraph.SceneAction]) -> [SceneActionSpec]? {
        var specs: [SceneActionSpec] = []
        for action in actions {
            guard let accessoryId = action.accessoryId else { return nil }
            specs.append(SceneActionSpec(
                accessoryId: accessoryId, service: action.service,
                characteristic: action.characteristic,
                value: HomeKitValue(rendered: action.valueDescription)
            ))
        }
        return specs
    }

    private static func eventSpecs(from events: [HomeGraph.EventRef]) -> [TriggerEventSpec]? {
        var specs: [TriggerEventSpec] = []
        for event in events {
            switch event.type {
            case "presence":
                specs.append(.presence(atHome: event.valueDescription == "atHome"))
            case "characteristic":
                guard let accessoryId = event.accessoryId, let characteristic = event.characteristicType else {
                    return nil
                }
                specs.append(.characteristic(
                    accessoryId: accessoryId, characteristic: characteristic,
                    value: event.valueDescription.map { HomeKitValue(rendered: $0) }
                ))
            default:
                return nil
            }
        }
        return specs
    }
}

extension HomeKitValue {
    /// The best typed value for a rendered reading, so a revert re-writes
    /// the prior value faithfully. HomeKit renders values as strings
    /// (NSNumber conventions); the declared format disambiguates the
    /// numeric-looking bools ("1"/"0").
    init(rendered: String, format: String? = nil) {
        if format?.lowercased() == "bool" {
            let lowered = rendered.lowercased()
            if lowered == "1" || lowered == "true" {
                self = .bool(true)
                return
            }
            if lowered == "0" || lowered == "false" {
                self = .bool(false)
                return
            }
        }
        if let int = Int(rendered) {
            self = .int(int)
        } else if let double = Double(rendered) {
            self = .double(double)
        } else {
            self = .string(rendered)
        }
    }
}
