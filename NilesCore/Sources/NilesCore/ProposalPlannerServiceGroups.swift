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
            card: memberNames.isEmpty
                ? [ProposalCardLine(.add, "Service group “\(trimmed)” · created")]
                : [ProposalCardLine(.add, "Service group “\(trimmed)” · created with \(memberNames.joined(separator: ", "))")]
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
}
