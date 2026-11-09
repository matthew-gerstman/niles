import Foundation

/// In-memory `HomeKitService` for unit tests and SwiftUI previews.
///
/// Tests must never touch `HMHomeManager` — the fake is the only home data
/// source they see. Seed it with a `HomeGraph`; when a test needs the world
/// to change mid-test, swap the graph with `setGraph(_:)`.
///
/// As `HomeKitWriting`, the fake also executes the proposal pipeline's
/// operation vocabulary against its graph with HomeKit's observable
/// semantics: deleted rooms hand their accessories to a "Default Room",
/// duplicate names are rejected, and created objects get generated ids.
public actor FakeHomeKitService: HomeKitWriting {
    public private(set) var graph: HomeGraph

    public init(graph: HomeGraph = HomeGraph()) {
        self.graph = graph
    }

    public func snapshot() async throws -> HomeGraph {
        graph
    }

    public func setGraph(_ newGraph: HomeGraph) {
        graph = newGraph
    }

    // MARK: - HomeKitWriting

    public func perform(_ operation: HomeKitOperation) async throws -> String? {
        switch operation {
        case .addRoom(let homeId, let name):
            let h = try indexOfHome(id: homeId)
            guard !graph.homes[h].rooms.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                throw HomeKitWriteError.duplicateName("Home already has a room named “\(name)”.")
            }
            let id = nextId(prefix: "room", existing: graph.homes[h].rooms.map(\.id))
            graph.homes[h].rooms.append(HomeGraph.Room(id: id, name: name))
            return id

        case .renameRoom(_, let roomId, let to):
            let (h, r) = try indexOfRoom(id: roomId)
            graph.homes[h].rooms[r].name = to
            return nil

        case .removeRoom(_, let roomId):
            let (h, r) = try indexOfRoom(id: roomId)
            // HomeKit's observable behavior: the deleted room's accessories
            // are reassigned to the default room.
            let displaced = graph.homes[h].rooms[r].accessories
            graph.homes[h].rooms.remove(at: r)
            guard !displaced.isEmpty else { return nil }
            if let d = graph.homes[h].rooms.firstIndex(where: { $0.name == "Default Room" }) {
                graph.homes[h].rooms[d].accessories.append(contentsOf: displaced)
            } else {
                let id = nextId(prefix: "room", existing: graph.homes[h].rooms.map(\.id))
                graph.homes[h].rooms.append(HomeGraph.Room(id: id, name: "Default Room", accessories: displaced))
            }
            return nil

        case .setZoneRooms(_, let zoneId, let addRoomIds, let removeRoomIds):
            let (h, z) = try indexOfZone(id: zoneId)
            for roomId in removeRoomIds {
                guard let index = graph.homes[h].zones[z].roomIds.firstIndex(of: roomId) else {
                    throw HomeKitWriteError.objectMissing("Zone “\(graph.homes[h].zones[z].name)” does not contain room \(roomId).")
                }
                graph.homes[h].zones[z].roomIds.remove(at: index)
            }
            for roomId in addRoomIds {
                guard room(id: roomId, inGraph: graph) != nil else {
                    throw HomeKitWriteError.objectMissing("No room \(roomId) to add to zone “\(graph.homes[h].zones[z].name)”.")
                }
                guard !graph.homes[h].zones[z].roomIds.contains(roomId) else { continue }
                graph.homes[h].zones[z].roomIds.append(roomId)
            }
            return nil

        case .addActionSet(_, let name, let actions):
            let h = try indexOfHome(havingSceneNamed: name)
            let id = nextId(prefix: "scene", existing: graph.homes[h].scenes.map(\.id))
            let rendered = actions.map { action(from: $0) }
            graph.homes[h].scenes.append(HomeGraph.Scene(id: id, name: name, type: "AppleScene", actions: rendered))
            return id

        case .setSceneActions(_, let sceneId, let add, let remove):
            let (h, s) = try indexOfScene(id: sceneId)
            graph.homes[h].scenes[s].actions.removeAll { action in remove.contains(SceneActionKey(action: action)) }
            let current = graph.homes[h].scenes[s].actions.map(SceneActionKey.init(action:))
            for spec in add where !current.contains(SceneActionKey(spec: spec)) {
                graph.homes[h].scenes[s].actions.append(action(from: spec))
            }
            return nil

        case .addServiceGroup(_, let name):
            let h = try indexOfHome(havingServiceGroupNamed: name)
            let id = nextId(prefix: "group", existing: graph.homes[h].serviceGroups.map(\.id))
            graph.homes[h].serviceGroups.append(HomeGraph.ServiceGroup(id: id, name: name))
            return id

        case .setServiceGroupMembers(_, let groupId, let addServiceIds, let removeServiceIds):
            let (h, g) = try indexOfServiceGroup(id: groupId)
            for serviceId in removeServiceIds {
                guard let index = graph.homes[h].serviceGroups[g].services.firstIndex(where: { $0.id == serviceId }) else {
                    throw HomeKitWriteError.objectMissing(
                        "Group “\(graph.homes[h].serviceGroups[g].name)” does not contain service \(serviceId)."
                    )
                }
                graph.homes[h].serviceGroups[g].services.remove(at: index)
            }
            for serviceId in addServiceIds {
                guard let ref = knownService(id: serviceId) else {
                    throw HomeKitWriteError.invalidOperation("No service \(serviceId) in any group of this home.")
                }
                guard !graph.homes[h].serviceGroups[g].services.contains(where: { $0.id == serviceId }) else { continue }
                graph.homes[h].serviceGroups[g].services.append(ref)
            }
            return nil

        case .removeServiceGroup(_, let groupId):
            let (h, g) = try indexOfServiceGroup(id: groupId)
            graph.homes[h].serviceGroups.remove(at: g)
            return nil

        case .addTimerTrigger(let homeId, let name, let fireDate, let recurrence, _):
            let h = try indexOfHome(id: homeId)
            let id = nextId(prefix: "trigger", existing: graph.homes[h].triggers.map(\.id))
            // Locked rule: triggers are born disabled, whatever the plan said.
            graph.homes[h].triggers.append(
                HomeGraph.Trigger(id: id, name: name, isEnabled: false, detail: .timer(fireDate: fireDate, recurrence: recurrence))
            )
            return id

        case .addEventTrigger(let homeId, let name, let events, _):
            let h = try indexOfHome(id: homeId)
            let id = nextId(prefix: "trigger", existing: graph.homes[h].triggers.map(\.id))
            graph.homes[h].triggers.append(
                HomeGraph.Trigger(
                    id: id, name: name, isEnabled: false,
                    detail: .event(events: events.map(Self.eventRef(from:)), predicate: Self.predicateDescription(events))
                )
            )
            return id
        }
    }

    // MARK: - Graph mutation internals

    /// The graph is a value type — mutations always go through
    /// `graph.homes[index]` subscripts, never through struct copies.

    /// Services are only reachable through groups (the graph's one service
    /// vocabulary); membership changes look refs up across all of them.
    private func knownService(id: String) -> HomeGraph.ServiceRef? {
        graph.homes.flatMap(\.serviceGroups).flatMap(\.services).first { $0.id == id }
    }

    /// Graph projection of a proposed event, mirroring the real adapter's
    /// read shape (HMCharacteristicEvent / HMPresenceEvent).
    private static func eventRef(from spec: TriggerEventSpec) -> HomeGraph.EventRef {
        switch spec {
        case .characteristic(_, let characteristic, let value):
            return HomeGraph.EventRef(
                type: "characteristic",
                characteristicType: characteristic,
                valueDescription: value?.rendered
            )
        case .presence(let atHome):
            return HomeGraph.EventRef(
                type: "presence",
                characteristicType: nil,
                valueDescription: atHome ? "atHome" : "away"
            )
        }
    }

    /// The predicate the real adapter derives from the events (presence
    /// events imply `predicateForEvaluatingTrigger(withPresence:)`). The fake
    /// records a human-readable equivalent.
    private static func predicateDescription(_ events: [TriggerEventSpec]) -> String? {
        let descriptions = events.map { (event: TriggerEventSpec) -> String in
            switch event {
            case .characteristic(_, let characteristic, let value):
                value.map { "\(characteristic) == \($0.rendered)" } ?? "\(characteristic) changes"
            case .presence(let atHome):
                "presence == \(atHome ? "atHome" : "away")"
            }
        }
        guard !descriptions.isEmpty else { return nil }
        return descriptions.joined(separator: " AND ")
    }

    private func action(from spec: SceneActionSpec) -> HomeGraph.SceneAction {
        let accessoryName = graph.homes
            .flatMap(\.rooms)
            .flatMap(\.accessories)
            .first { $0.id == spec.accessoryId }?.name
        return HomeGraph.SceneAction(
            accessoryId: spec.accessoryId,
            accessoryName: accessoryName,
            service: spec.service,
            characteristic: spec.characteristic,
            characteristicName: nil,
            valueDescription: spec.value.rendered
        )
    }

    private func nextId(prefix: String, existing: [String]) -> String {
        let used = Set(existing)
        var n = 1
        while used.contains("\(prefix)-\(n)") { n += 1 }
        return "\(prefix)-\(n)"
    }

    private func indexOfHome(id: String) throws -> Int {
        guard let index = graph.homes.firstIndex(where: { $0.id == id }) else {
            throw HomeKitWriteError.objectMissing("No home \(id).")
        }
        return index
    }

    /// Scenes are per-home; a create lands in the first home. Duplicate
    /// names are rejected the way HomeKit's are, across all homes.
    private func indexOfHome(havingSceneNamed name: String) throws -> Int {
        if graph.homes.contains(
            where: { $0.scenes.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
        ) {
            throw HomeKitWriteError.duplicateName("Home already has a scene named “\(name)”.")
        }
        guard let index = graph.homes.indices.first else {
            throw HomeKitWriteError.objectMissing("No home exists to hold scene “\(name)”.")
        }
        return index
    }

    private func indexOfHome(havingServiceGroupNamed name: String) throws -> Int {
        if graph.homes.contains(
            where: { $0.serviceGroups.contains { $0.name.caseInsensitiveCompare(name) == .orderedSame } }
        ) {
            throw HomeKitWriteError.duplicateName("Home already has a service group named “\(name)”.")
        }
        guard let index = graph.homes.indices.first else {
            throw HomeKitWriteError.objectMissing("No home exists to hold service group “\(name)”.")
        }
        return index
    }

    private func indexOfRoom(id: String) throws -> (home: Int, room: Int) {
        for h in graph.homes.indices {
            if let r = graph.homes[h].rooms.firstIndex(where: { $0.id == id }) {
                return (h, r)
            }
        }
        throw HomeKitWriteError.objectMissing("No room \(id).")
    }

    private func indexOfZone(id: String) throws -> (home: Int, zone: Int) {
        for h in graph.homes.indices {
            if let z = graph.homes[h].zones.firstIndex(where: { $0.id == id }) {
                return (h, z)
            }
        }
        throw HomeKitWriteError.objectMissing("No zone \(id).")
    }

    private func indexOfScene(id: String) throws -> (home: Int, scene: Int) {
        for h in graph.homes.indices {
            if let s = graph.homes[h].scenes.firstIndex(where: { $0.id == id }) {
                return (h, s)
            }
        }
        throw HomeKitWriteError.objectMissing("No scene \(id).")
    }

    private func indexOfServiceGroup(id: String) throws -> (home: Int, group: Int) {
        for h in graph.homes.indices {
            if let g = graph.homes[h].serviceGroups.firstIndex(where: { $0.id == id }) {
                return (h, g)
            }
        }
        throw HomeKitWriteError.objectMissing("No service group \(id).")
    }

    private func room(id: String, inGraph graph: HomeGraph) -> HomeGraph.Room? {
        graph.homes.flatMap(\.rooms).first { $0.id == id }
    }
}
