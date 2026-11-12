import Foundation

/// One member of a `stage_batch` call (Blueprint art_iN2CYQKa): a staged
/// write tool's name and its normal arguments, exactly as the individual
/// tool would have taken them.
public struct BatchOperation: Sendable, Equatable {
    public let tool: String
    public let arguments: [String: ToolArgument]?

    public init(tool: String, arguments: [String: ToolArgument]?) {
        self.tool = tool
        self.arguments = arguments
    }
}

extension ProposalStore {
    /// The name every merged batch plan carries, so dedupe can tell a batch
    /// from a single-tool proposal — and so the app's read models can tell
    /// a batch row (whose summary line says something the title does not)
    /// from a single-op row (whose first card line restates the title).
    public static let batchToolName = "stage_batch"

    /// Merges the members' plans into one batch Plan: their operations and
    /// diff entries concatenated in order, destructive if any member is, and
    /// a review card with one introduced section per member — each section's
    /// lines are exactly what the single tool would have produced. Pure;
    /// `stageBatch` stages the result through the ordinary dedupe-and-
    /// persist path, and approval runs it like any multi-operation proposal.
    static func merge(_ plans: [Plan]) -> Plan {
        let title = "Batch: \(plans.count) changes"
        var card: [ProposalCardLine] = []
        for (index, plan) in plans.enumerated() {
            card.append(ProposalCardLine(.note, "— Operation \(index + 1) of \(plans.count): \(plan.title) —"))
            card += plan.card
        }
        return Plan(
            tool: batchToolName,
            title: title,
            summary: "\(title) — \(batchComposition(of: plans)).",
            isDestructive: plans.contains { $0.isDestructive },
            operations: plans.flatMap(\.operations),
            entries: plans.flatMap(\.entries),
            card: card
        )
    }

    /// "3 scene creates, 2 renames" — each member's resolved per-type tool
    /// counted in first-appearance order, for the batch summary line.
    static func batchComposition(of plans: [Plan]) -> String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for plan in plans {
            if counts[plan.tool] == nil { order.append(plan.tool) }
            counts[plan.tool, default: 0] += 1
        }
        return order
            .map { tool in
                let count = counts[tool]!
                return "\(count) \(pluralized(memberNoun(tool), count: count))"
            }
            .joined(separator: ", ")
    }

    /// One member's planning failure reduced to its reason — the per-entry
    /// error line prefixes the operation index and tool. The single-tool
    /// staging path renders these same errors through `WriteToolRegistry`;
    /// here they are attributed per member instead.
    static func planningFailureMessage(_ error: Error) -> String {
        switch error {
        case let plannerError as ProposalPlanner.PlannerError:
            plannerError.message
        case let storeError as ProposalStoreError:
            switch storeError {
            case .invalidArguments(let detail):
                detail
            case .unknownTool(let name):
                "Unknown tool \(name)."
            case .validationFailed(let messages):
                messages.joined(separator: " ")
            default:
                String(describing: storeError)
            }
        default:
            String(describing: error)
        }
    }

    private static let memberNouns: [String: String] = [
        "create_room": "room create",
        "create_zone": "zone create",
        "create_scene": "scene create",
        "create_service_group": "group create",
        "create_timer_trigger": "timer create",
        "create_event_trigger": "automation create",
        "rename": "rename",
        "rename_room": "rename",
        "rename_zone": "rename",
        "rename_scene": "rename",
        "rename_service_group": "rename",
        "rename_accessory": "rename",
        "delete": "delete",
        "delete_room": "delete",
        "delete_zone": "delete",
        "delete_scene": "delete",
        "delete_service_group": "delete",
        "delete_trigger": "delete",
        "remove_accessory": "accessory removal",
        "update": "update",
        "set_zone_rooms": "zone update",
        "set_scene_actions": "scene update",
        "set_service_group_members": "group update",
        "update_event_trigger": "automation update",
        "execute_scene": "scene execution",
        "write_characteristic": "characteristic write",
        "identify_accessory": "identify",
        "unblock_accessory": "unblock",
        "assign_accessory_to_room": "accessory move",
    ]

    private static func memberNoun(_ tool: String) -> String {
        memberNouns[tool] ?? tool.replacingOccurrences(of: "_", with: " ")
    }

    private static func pluralized(_ noun: String, count: Int) -> String {
        guard count > 1 else { return noun }
        guard let lastSpace = noun.lastIndex(of: " ") else { return noun + "s" }
        return String(noun[noun.startIndex..<lastSpace]) + " " + String(noun[noun.index(after: lastSpace)...]) + "s"
    }
}
