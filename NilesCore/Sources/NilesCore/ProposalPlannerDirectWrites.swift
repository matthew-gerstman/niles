import Foundation

extension ProposalPlanner {
    // MARK: - Direct writes (device-immediate)

    /// Spec (direct control, device-immediate): one characteristic write
    /// that applies to the device the moment approval lands. Staging checks
    /// the value against the characteristic's declared metadata with the
    /// same shared check resolution runs — a rejection names the
    /// characteristic, its current reading, and why the target can never
    /// fit, and a proposal that stages always executes.
    static func writeCharacteristic(
        accessoryId: String, service: String?, characteristic: String, value: HomeKitValue, graph: HomeGraph
    ) throws -> Plan {
        let (home, accessory) = try self.accessory(id: accessoryId, in: graph)
        var card: [ProposalCardLine] = []
        switch capability(characteristic: characteristic, service: service, in: accessory) {
        case .supported:
            break
        case .unverifiable:
            card.append(ProposalCardLine(
                .note,
                "⚠ Could not verify \(characteristic) support — “\(accessory.name)”'s "
                    + "capability data is unavailable; approval may still fail at execution."
            ))
        case .unsupported(let error):
            throw error
        }
        let ref = accessory.characteristic(characteristic, service: service)
        let kind = DeviceHomeView.ValueKind(format: ref?.metadata?.format)
        if let why = DeviceWriteResolver.valueViolation(value, kind: kind, metadata: ref?.metadata) {
            let current = ref?.valueDescription.map { "currently reads \($0)" } ?? "has no current reading"
            throw PlannerError.invalidInput(
                "Characteristic \(characteristic) on “\(accessory.name)” \(current) — "
                    + "target \(value.rendered) rejected: \(why)."
            )
        }
        if ref?.valueDescription == value.rendered {
            throw PlannerError.noChange(
                "“\(accessory.name)” \(characteristic) already reads \(value.rendered)."
            )
        }
        let label = ref?.name ?? characteristic
        let current = ref?.valueDescription ?? "unknown"
        card.insert(ProposalCardLine(
            .plain,
            "\(accessory.name): \(label) \(current) → \(value.rendered)"
        ), at: 0)
        card.append(ProposalCardLine(
            .note,
            "⚠ Device-immediate — the value applies to the device the moment this is approved."
        ))
        let spec = SceneActionSpec(
            accessoryId: accessory.id, service: service, characteristic: characteristic, value: value
        )
        return Plan(
            tool: "write_characteristic",
            title: "Set “\(accessory.name)” \(label) to \(value.rendered)",
            summary: "Set “\(accessory.name)” \(label) to \(value.rendered) now",
            isDestructive: false,
            operations: [.writeCharacteristic(homeId: home.id, action: spec)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .accessory, id: accessory.id, name: accessory.name),
                op: .update,
                before: ref?.valueDescription,
                after: value.rendered
            )],
            card: card
        )
    }
}
