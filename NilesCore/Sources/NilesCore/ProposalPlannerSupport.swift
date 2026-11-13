import Foundation

extension ProposalPlanner {
    // MARK: - Shared helpers

    static func home(id: String, in graph: HomeGraph) throws -> HomeGraph.Home {
        guard let home = graph.homes.first(where: { $0.id == id }) else {
            throw PlannerError.unknownHome(id)
        }
        return home
    }

    static func room(id: String, in home: HomeGraph.Home) -> HomeGraph.Room? {
        home.rooms.first { $0.id == id }
    }

    static func room(id: String, in graph: HomeGraph) throws -> (HomeGraph.Home, HomeGraph.Room) {
        for home in graph.homes {
            if let room = Self.room(id: id, in: home) { return (home, room) }
        }
        throw PlannerError.unknownRoom(id)
    }

    static func zone(id: String, in graph: HomeGraph) throws -> (HomeGraph.Home, HomeGraph.Zone) {
        for home in graph.homes {
            if let zone = home.zones.first(where: { $0.id == id }) { return (home, zone) }
        }
        throw PlannerError.unknownZone(id)
    }

    static func scene(id: String, in graph: HomeGraph) throws -> (HomeGraph.Home, HomeGraph.Scene) {
        for home in graph.homes {
            if let scene = home.scenes.first(where: { $0.id == id }) { return (home, scene) }
        }
        throw PlannerError.unknownScene(id)
    }

    static func serviceGroup(id: String, in graph: HomeGraph) throws -> (HomeGraph.Home, HomeGraph.ServiceGroup) {
        for home in graph.homes {
            if let group = home.serviceGroups.first(where: { $0.id == id }) { return (home, group) }
        }
        throw PlannerError.unknownServiceGroup(id)
    }

    static func trigger(id: String, in graph: HomeGraph) throws -> (HomeGraph.Home, HomeGraph.Trigger) {
        for home in graph.homes {
            if let trigger = home.triggers.first(where: { $0.id == id }) { return (home, trigger) }
        }
        throw PlannerError.unknownTrigger(id)
    }

    static func accessory(id: String, in graph: HomeGraph) throws -> (HomeGraph.Home, HomeGraph.Accessory) {
        for home in graph.homes {
            for room in home.rooms {
                if let accessory = room.accessories.first(where: { $0.id == id }) {
                    return (home, accessory)
                }
            }
        }
        throw PlannerError.invalidInput("No accessory with id \(id). Accessory ids come from get_rooms.")
    }

    /// A trigger runs an existing scene (HomeKit binds an action set to a
    /// trigger); referencing one that does not exist in the same home is an
    /// eager-validation failure, never a staged surprise.
    static func sceneReference(_ sceneId: String?, in home: HomeGraph.Home) throws -> HomeGraph.Scene? {
        guard let sceneId, !sceneId.isEmpty else { return nil }
        guard let scene = home.scenes.first(where: { $0.id == sceneId }) else {
            throw PlannerError.unknownScene(sceneId)
        }
        return scene
    }

    static func roomName(id: String, home: HomeGraph.Home) -> String {
        room(id: id, in: home)?.name ?? id
    }

    static func requiredName(_ name: String, kind: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw PlannerError.invalidInput("\(kind.capitalized) name must not be empty.")
        }
        return trimmed
    }

    /// Names written through HomeKit's `updateName` family (rooms, zones,
    /// scenes, service groups, accessories) face its naming rules — see
    /// `DeviceWriteResolver.nameViolation`, the same check the executor's
    /// resolution runs. Rejecting here keeps staging and execution in
    /// agreement: nothing reaches approval that HomeKit will refuse.
    static func requiredHomeKitName(
        _ name: String, kind: String, subject: String? = nil
    ) throws -> String {
        let trimmed = try requiredName(name, kind: kind)
        if let why = DeviceWriteResolver.nameViolation(trimmed) {
            // Standing rule: errors name the object. Renames pass the
            // object's current identity; creations let the proposed name
            // speak for itself.
            let what = subject.map { "\($0) cannot use “\(trimmed)” as its name" }
                ?? "\(kind.capitalized) name “\(trimmed)” is not a valid HomeKit name"
            throw PlannerError.invalidInput("\(what): \(why).")
        }
        return trimmed
    }

    static func rejectDuplicate(kind: String, name: String, in names: [String], homeName: String) throws {
        if names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            throw PlannerError.duplicateName(kind: kind, name: name, home: homeName)
        }
    }

    /// A human description of an event as it currently exists in the graph —
    /// the "before" side of an event-trigger edit's diff.
    static func describe(event ref: HomeGraph.EventRef, accessoryName: String) -> String {
        if ref.type.lowercased().contains("presence") {
            switch ref.valueDescription?.lowercased() {
            case "athome": return "someone arrives home"
            case "away": return "everyone is away"
            default: return "a presence change"
            }
        }
        let characteristicName = ref.characteristicType ?? "a characteristic"
        if let value = ref.valueDescription {
            return "\(accessoryName) \(characteristicName) reaches \(value)"
        }
        return "\(accessoryName) \(characteristicName) changes"
    }

    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    static func weekdayName(_ weekday: Int) -> String {
        (1...7).contains(weekday) ? Self.weekdayNames[weekday - 1] : "day \(weekday)"
    }

    /// Event-trigger recurrences are days of the week (HomeKit honors only
    /// the `weekday` component on HMEventTrigger) — the same rule the resolver
    /// enforces at execution, stated eagerly so the agent fixes the request
    /// before staging.
    static func validateEventTriggerRecurrences(_ recurrences: [[String: Int]]?) throws {
        for components in recurrences ?? [] {
            guard components.count == 1, let weekday = components["weekday"], (1...7).contains(weekday) else {
                throw PlannerError.invalidInput(
                    "Event-trigger recurrences are days of the week — one “weekday” component (1…7, 1 = Sunday) per entry."
                )
            }
        }
    }

    /// Eager per-event validation (spec): every proposed characteristic event
    /// must reference an accessory that exists in the home today and — when
    /// capability data is available — a characteristic it actually supports.
    /// All failures are collected, so the agent fixes everything in one
    /// retry; missing capability data degrades to a permissive card note.
    static func validate(events: [TriggerEventSpec], home: HomeGraph.Home) throws -> [ProposalCardLine] {
        var failures: [String] = []
        var notes: [ProposalCardLine] = []
        for (index, event) in events.enumerated() {
            guard case .characteristic(let accessoryId, let characteristic, _) = event else { continue }
            guard let accessory = accessory(id: accessoryId, in: home) else {
                let error = PlannerError.unknownAccessory(id: accessoryId, home: home.name)
                failures.append("Event \(index + 1): \(error.message)")
                continue
            }
            switch capability(characteristic: characteristic, service: nil, in: accessory) {
            case .supported:
                break
            case .unverifiable:
                notes.append(ProposalCardLine(
                    .note,
                    "⚠ Could not verify \(characteristic) support — “\(accessory.name)”'s "
                        + "capability data is unavailable; approval may still fail at execution."
                ))
            case .unsupported(let error):
                failures.append("Event \(index + 1): \(error.message)")
            }
        }
        if !failures.isEmpty {
            throw PlannerError.validationFailed(failures)
        }
        return notes
    }

    // MARK: - Capability checks

    /// The outcome of a staging-time capability check against the graph's
    /// accessory services.
    enum Capability {
        case supported
        /// No characteristic data to judge against — staging stays permissive.
        case unverifiable
        case unsupported(PlannerError)
    }

    /// Whether an accessory supports a characteristic, mirroring the
    /// executor's resolution (`DeviceWriteResolver.resolveAction`): the
    /// characteristic is identified by type UUID or its metadata name (the
    /// shared rule settled with the write-resolver fix so staging and
    /// execution read the same DeviceHomeView shape), and the service
    /// name-or-type filter matches when the spec names a service — so
    /// staging never passes anything execution would reject. Accessories
    /// whose services list no characteristics (a graph without capability
    /// reads) are unverifiable.
    static func capability(
        characteristic: String, service: String?, in accessory: HomeGraph.Accessory
    ) -> Capability {
        guard accessory.services.contains(where: { !$0.characteristics.isEmpty }) else {
            return .unverifiable
        }
        let services: [HomeGraph.AccessoryService]
        if let wanted = service {
            services = accessory.services.filter {
                $0.name.caseInsensitiveCompare(wanted) == .orderedSame
                    || $0.serviceType.map { $0.caseInsensitiveCompare(wanted) == .orderedSame } == true
            }
            if services.isEmpty {
                return .unsupported(.unknownServiceOnAccessory(accessory: accessory.name, service: wanted))
            }
        } else {
            services = accessory.services
        }
        let matches: (HomeGraph.CharacteristicRef) -> Bool = { ref in
            ref.type == characteristic
                || ref.name.map { $0.caseInsensitiveCompare(characteristic) == .orderedSame } == true
        }
        guard services.contains(where: { $0.characteristics.contains(where: matches) }) else {
            return .unsupported(.unsupportedCharacteristic(accessory: accessory.name, characteristic: characteristic))
        }
        return .supported
    }

    /// "fires 2026-11-09T07:30:00Z, repeating {hour: 7, minute: 30}".
    static func timerLine(fireDate: Date, recurrence: [String: Int]) -> String {
        var line = "Fires \(ISOTimestamps.render(fireDate))"
        if !recurrence.isEmpty {
            line += ", repeating \(Self.recurrenceDescription(recurrence))"
        }
        return line
    }

    static func recurrenceDescription(_ recurrence: [String: Int]) -> String {
        let order = ["year", "month", "weekday", "day", "hour", "minute", "second"]
        let parts = order
            .compactMap { key -> String? in recurrence[key].map { "\(key): \($0)" } }
            .joined(separator: ", ")
        return "{\(parts)}"
    }

    static func timerFireDate(of trigger: HomeGraph.Trigger) -> Date {
        if case .timer(let fireDate, _) = trigger.detail { return fireDate }
        return Date()
    }

    static func timerRecurrence(of trigger: HomeGraph.Trigger) -> [String: Int] {
        if case .timer(_, let recurrence) = trigger.detail { return recurrence }
        return [:]
    }

    /// Eager per-action validation (spec): every proposed scene action must
    /// reference an accessory that exists in the home today and — when the
    /// graph carries capability data (the read side's accessory services
    /// with their characteristics) — a characteristic the accessory actually
    /// supports. All failures are collected, so the agent fixes everything in
    /// one retry. When an accessory exposes no characteristic data the
    /// support check degrades to permissive and the returned card note says
    /// so; a rejection here always precedes a human seeing a card.
    static func validate(
        accessories actions: [SceneActionSpec], home: HomeGraph.Home
    ) throws -> [ProposalCardLine] {
        var failures: [String] = []
        var notes: [ProposalCardLine] = []
        for (index, action) in actions.enumerated() {
            guard let accessory = accessory(id: action.accessoryId, in: home) else {
                let error = PlannerError.unknownAccessory(id: action.accessoryId, home: home.name)
                failures.append("Action \(index + 1): \(error.message)")
                continue
            }
            switch capability(characteristic: action.characteristic, service: action.service, in: accessory) {
            case .supported:
                // Capability alone is not enough — the value must fit the
                // characteristic's declared metadata (the shared check the
                // executor's resolution runs over the same derived kind and
                // metadata mapping). The Power State '0' QA failure passed
                // capability and died at execution; this closes that gap.
                if let ref = accessory.characteristic(action.characteristic, service: action.service) {
                    let kind = DeviceHomeView.ValueKind(format: ref.metadata?.format)
                    if let why = DeviceWriteResolver.valueViolation(action.value, kind: kind, metadata: ref.metadata) {
                        failures.append(
                            "Action \(index + 1): Characteristic \(action.characteristic) on “\(accessory.name)” "
                                + "cannot take \(action.value.rendered): \(why)."
                        )
                    }
                }
            case .unverifiable:
                notes.append(ProposalCardLine(
                    .note,
                    "⚠ Could not verify \(action.characteristic) support — “\(accessory.name)”'s "
                        + "capability data is unavailable; approval may still fail at execution."
                ))
            case .unsupported(let error):
                failures.append("Action \(index + 1): \(error.message)")
            }
        }
        if !failures.isEmpty {
            throw PlannerError.validationFailed(failures)
        }
        return notes
    }

    /// Display line for a proposed action: "Desk Lamp: Brightness → 30".
    static func describe(spec: SceneActionSpec, home: HomeGraph.Home) -> String {
        let accessory = accessoryName(of: spec.accessoryId, in: home) ?? spec.accessoryId
        let label = characteristicLabel(for: spec.characteristic, in: home)
        return "\(accessory): \(label) → \(spec.value.rendered)"
    }

    /// Display line for an action read from the graph.
    static func describe(action: HomeGraph.SceneAction, home: HomeGraph.Home) -> String {
        let accessory = action.accessoryName ?? action.accessoryId ?? "unknown accessory"
        let label = action.characteristicName ?? action.characteristic
        return "\(accessory): \(label) → \(action.valueDescription)"
    }

    static func accessory(id: String, in home: HomeGraph.Home) -> HomeGraph.Accessory? {
        home.rooms.flatMap { $0.accessories }.first { $0.id == id }
    }

    static func accessoryName(of id: String, in home: HomeGraph.Home) -> String? {
        accessory(id: id, in: home)?.name
    }

    /// Borrow a human label for a characteristic type from any scene action in
    /// the home that already carries one; unknown types fall back to the type
    /// string itself. Display-only — proposals are keyed by type.
    static func characteristicLabel(for type: String, in home: HomeGraph.Home) -> String {
        for scene in home.scenes {
            for action in scene.actions where action.characteristic == type {
                if let name = action.characteristicName { return name }
            }
        }
        return type
    }
}
