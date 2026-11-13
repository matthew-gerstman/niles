import Foundation

extension ProposalPlanner {
    // MARK: - Service groups

    static func createServiceGroup(
        homeId: String, name: String, serviceIds: [String], graph: HomeGraph
    ) throws -> Plan {
        let trimmed = try requiredHomeKitName(name, kind: "service group")
        let home = try self.home(id: homeId, in: graph)
        try rejectDuplicate(kind: "service group", name: trimmed, in: home.serviceGroups.map(\.name), homeName: home.name)
        // Members are validated at plan time so a stale id fails here, in
        // band, instead of mid-execution.
        let knownServiceIds = Set(
            home.rooms.flatMap(\.accessories).flatMap(\.services).map(\.id)
        )
        let unknown = Set(serviceIds).subtracting(knownServiceIds).sorted()
        guard unknown.isEmpty else {
            throw PlannerError.invalidInput(
                "No service \(unknown.joined(separator: ", ")) in “\(home.name)”."
            )
        }
        let memberAccessories = home.rooms.flatMap(\.accessories)
            .filter { accessory in accessory.services.contains { serviceIds.contains($0.id) } }
        let memberNames = memberAccessories.map(\.name)
        // The planner half of the cross-group rule the device resolver also
        // runs (the `valueViolation` pattern): a member-add whose service
        // already belongs to another group fails here, in band, before a
        // proposal ever exists.
        try rejectAlreadyGrouped(serviceIds, excluding: nil, in: home)
        var card: [ProposalCardLine] = memberNames.isEmpty
            ? [ProposalCardLine(.add, "Service group “\(trimmed)” · created")]
            : [ProposalCardLine(.add, "Service group “\(trimmed)” · created with \(memberNames.joined(separator: ", "))")]
        if let warning = windowCoveringCardLine(for: serviceIds, in: home) {
            card.append(warning)
        }
        return Plan(
            tool: "create_service_group",
            title: "Create service group “\(trimmed)”",
            summary: memberNames.isEmpty
                ? "Create service group “\(trimmed)” in “\(home.name)”"
                : "Create service group “\(trimmed)” in “\(home.name)” with \(memberNames.count) \(memberNames.count == 1 ? "member" : "members")",
            isDestructive: false,
            operations: [.addServiceGroup(homeId: home.id, name: trimmed, serviceIds: serviceIds)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .serviceGroup, id: "", name: trimmed),
                op: .create,
                before: nil,
                after: trimmed
            )],
            card: card
        )
    }

    static func renameServiceGroup(groupId: String, name: String, graph: HomeGraph) throws -> Plan {
        let (home, group) = try self.serviceGroup(id: groupId, in: graph)
        let trimmed = try requiredHomeKitName(name, kind: "service group", subject: "Service group “\(group.name)”")
        if group.name.caseInsensitiveCompare(trimmed) == .orderedSame {
            throw PlannerError.noChange("service group “\(group.name)” is already named “\(trimmed)”.")
        }
        // Group names are unique within a home; the new name cannot collide
        // with another group — this one included.
        let otherGroups = home.serviceGroups.filter { $0.id != group.id }
        try rejectDuplicate(kind: "service group", name: trimmed, in: otherGroups.map(\.name), homeName: home.name)
        return Plan(
            tool: "rename_service_group",
            title: "Rename service group “\(group.name)”",
            summary: "Rename service group “\(group.name)” to “\(trimmed)”",
            isDestructive: false,
            operations: [.renameServiceGroup(homeId: home.id, groupId: group.id, to: trimmed)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .serviceGroup, id: group.id, name: group.name),
                op: .rename,
                before: group.name,
                after: trimmed
            )],
            card: [ProposalCardLine(.plain, "Service group “\(group.name)” → “\(trimmed)”")]
        )
    }

    static func setServiceGroupMembers(groupId: String, serviceIds: [String], graph: HomeGraph) throws -> Plan {
        let (home, group) = try self.serviceGroup(id: groupId, in: graph)

        // Validate against every service visible in the home. Group members
        // carry richer display names, but a service on a standalone
        // accessory — not yet in any group — is equally real; rejecting it
        // would make grouping that accessory impossible.
        var known = Dictionary(
            home.serviceGroups.flatMap(\.services).map { ($0.id, $0.name) },
            uniquingKeysWith: { first, _ in first }
        )
        for service in home.rooms.flatMap(\.accessories).flatMap(\.services)
        where known[service.id] == nil {
            known[service.id] = service.name
        }
        var failures: [String] = []
        for serviceId in serviceIds where known[serviceId] == nil {
            failures.append("Service \(serviceId): \(PlannerError.unknownService(serviceId).message)")
        }
        if !failures.isEmpty {
            throw PlannerError.validationFailed(failures)
        }

        var seen = Set<String>()
        let target = serviceIds.filter { seen.insert($0).inserted }
        let current = group.services.map(\.id)
        let additions = target.filter { !current.contains($0) }
        let removals = current.filter { !target.contains($0) }
        if additions.isEmpty && removals.isEmpty {
            throw PlannerError.noChange("service group “\(group.name)” already has exactly these members.")
        }
        // The planner half of the cross-group rule the device resolver also
        // runs (the `valueViolation` pattern): a member-add whose service
        // already belongs to another group fails here, in band, before a
        // proposal ever exists.
        try rejectAlreadyGrouped(additions, excluding: group, in: home)

        let groupRef = ProposalObjectRef(kind: .serviceGroup, id: group.id, name: group.name)
        let entries: [ProposalDiffEntry] =
            additions.map { serviceId in
                ProposalDiffEntry(
                    object: groupRef, op: .addMembers,
                    before: nil, after: known[serviceId] ?? serviceId
                )
            }
            + removals.map { serviceId in
                ProposalDiffEntry(
                    object: groupRef, op: .removeMembers,
                    before: known[serviceId] ?? serviceId, after: nil
                )
            }

        var card: [ProposalCardLine] =
            additions.map { serviceId in
                ProposalCardLine(.add, "“\(group.name)” · add service “\(known[serviceId] ?? serviceId)”")
            }
            + removals.map { serviceId in
                ProposalCardLine(.remove, "“\(group.name)” · remove service “\(known[serviceId] ?? serviceId)”")
            }
        let unchanged = current.count - removals.count
        if unchanged > 0 {
            let noun = unchanged == 1 ? "member" : "members"
            card.append(ProposalCardLine(.plain, "\(unchanged) existing \(noun) unchanged."))
        }
        if let warning = windowCoveringCardLine(for: additions, in: home) {
            card.append(warning)
        }

        return Plan(
            tool: "set_service_group_members",
            title: "Update service group “\(group.name)”",
            summary: "Update service group “\(group.name)” members (\(additions.count) added, \(removals.count) removed)",
            isDestructive: false,
            operations: [.setServiceGroupMembers(
                homeId: home.id, groupId: group.id,
                addServiceIds: additions, removeServiceIds: removals
            )],
            entries: entries,
            card: card
        )
    }

    static func deleteServiceGroup(groupId: String, graph: HomeGraph) throws -> Plan {
        let (home, group) = try self.serviceGroup(id: groupId, in: graph)
        return Plan(
            tool: "delete_service_group",
            title: "Delete service group “\(group.name)”",
            summary: "Delete service group “\(group.name)”",
            isDestructive: true,
            operations: [.removeServiceGroup(homeId: home.id, groupId: group.id)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .serviceGroup, id: group.id, name: group.name),
                op: .delete,
                before: group.name,
                after: nil
            )],
            card: [
                ProposalCardLine(.remove, "Service group “\(group.name)” · deleted"),
                // Groups are labels over services; deleting one touches no device.
                ProposalCardLine(.plain, "Devices are unaffected — a group is a label over services."),
            ]
        )
    }

    /// The cross-group rule, planner half: HomeKit refuses a service that
    /// already belongs to another group (HMError 3 felled the first
    /// blind-grouping batch at execution). Reject the member-add here,
    /// naming the service and the group that holds it, so the failure lands
    /// in band at staging instead.
    ///
    /// Honest limit: HomeKit reports group membership empty in this process
    /// and offers no public refresh API (see the read-side note PR #117
    /// added), so this check is only as good as the graph's projection —
    /// it is not a categorical guarantee.
    private static func rejectAlreadyGrouped(
        _ serviceIds: [String], excluding excluded: HomeGraph.ServiceGroup?, in home: HomeGraph.Home
    ) throws {
        for serviceId in serviceIds {
            for other in home.serviceGroups
            where other.id != excluded?.id && other.services.contains(where: { $0.id == serviceId }) {
                let label = home.rooms.flatMap(\.accessories).flatMap(\.services)
                    .first(where: { $0.id == serviceId })?.name ?? serviceId
                throw PlannerError.invalidInput(
                    "\(label) already belongs to group “\(other.name)”. Remove it there first."
                )
            }
        }
    }

    // MARK: - The window-covering known-unknown

    /// HomeKit's window-covering service type as the graph projects it.
    private static let windowCoveringServiceType = "0000006C-0000-1000-8000-0026BB765291"

    /// The known-unknown the diagnostic run established (prop_19170189aed5,
    /// approved and executed on the Duo): HomeKit refused a window-covering
    /// member-add with HMError 3 on a ~25-hour-old group, so freshness is
    /// ruled out and the refusal looks categorical. This is information, not
    /// a validation rule — the membership change still stages, and the
    /// reviewer decides with the warning on the card.
    private static let windowCoveringWarning =
        "HomeKit may refuse this membership change: HMError 3, invalidParameter, "
            + "observed on Eve MotionBlinds regardless of group age."

    /// Names the window-covering services among `serviceIds`, looking through
    /// both projections the graph carries — services standing in groups
    /// (ServiceRef) and services under rooms/accessories (AccessoryService).
    private static func windowCoveringNames(
        among serviceIds: [String], in home: HomeGraph.Home
    ) -> [String] {
        let wanted = Set(serviceIds)
        var byId: [String: String] = [:]
        for service in home.rooms.flatMap(\.accessories).flatMap(\.services)
        where wanted.contains(service.id) && service.serviceType == windowCoveringServiceType {
            byId[service.id] = service.name
        }
        for ref in home.serviceGroups.flatMap(\.services)
        where wanted.contains(ref.id) && ref.serviceType == windowCoveringServiceType {
            byId[ref.id] = byId[ref.id] ?? ref.name
        }
        return byId.values.sorted()
    }

    /// The warning line for a membership change that adds window coverings,
    /// or nil when none of the added services is one.
    private static func windowCoveringCardLine(
        for additions: [String], in home: HomeGraph.Home
    ) -> ProposalCardLine? {
        guard !windowCoveringNames(among: additions, in: home).isEmpty else { return nil }
        return ProposalCardLine(.note, "⚠ \(windowCoveringWarning)")
    }
}