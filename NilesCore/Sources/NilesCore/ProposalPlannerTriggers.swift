import Foundation

extension ProposalPlanner {
    // MARK: - Triggers

    /// Spec locked decision: creation NEVER arms. Every trigger this tool
    /// adds lands disabled; enabling is `set_trigger_state`, which stages
    /// its own separately-approved proposal. An agent can therefore never
    /// silently flip an automation on.

    static func createTimerTrigger(
        homeId: String, name: String, fireDate: Date, recurrence: [String: Int],
        sceneId: String?, graph: HomeGraph
    ) throws -> Plan {
        let trimmed = try requiredName(name, kind: "trigger")
        let home = try self.home(id: homeId, in: graph)
        let scene = try sceneReference(sceneId, in: home)

        var card: [ProposalCardLine] = [
            ProposalCardLine(.add, "Timer trigger “\(trimmed)” · created DISABLED"),
            ProposalCardLine(.plain, timerLine(fireDate: fireDate, recurrence: recurrence)),
        ]
        if let scene { card.append(ProposalCardLine(.plain, "Runs scene “\(scene.name)” when it fires.")) }
        if scene == nil {
            card.append(ProposalCardLine(
                .note, "⚠ Created without a scene — HomeKit cannot arm it; recreate with a scene to enable it later."
            ))
        }
        card.append(ProposalCardLine(
            .note, "⚠ Created disabled — arming it takes a separate set_trigger_state approval."
        ))

        return Plan(
            tool: "create_timer_trigger",
            title: "Create timer trigger “\(trimmed)”",
            summary: "Create timer trigger “\(trimmed)” (disabled)",
            isDestructive: false,
            operations: [.addTimerTrigger(
                homeId: home.id, name: trimmed, fireDate: fireDate, recurrence: recurrence, sceneId: scene?.id
            )],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .trigger, id: "", name: trimmed),
                op: .create,
                before: nil,
                after: "disabled"
            )],
            card: card
        )
    }

    static func createEventTrigger(
        homeId: String, name: String, events: [TriggerEventSpec], endEvents: [TriggerEventSpec],
        executeOnce: Bool, sceneId: String?, graph: HomeGraph
    ) throws -> Plan {
        let trimmed = try requiredName(name, kind: "trigger")
        let home = try self.home(id: homeId, in: graph)
        let scene = try sceneReference(sceneId, in: home)
        let capabilityNotes = try validate(events: events, home: home)
            + validate(events: endEvents, home: home)

        var card: [ProposalCardLine] = [
            ProposalCardLine(.add, "Event trigger “\(trimmed)” · created DISABLED"),
        ]
        card += events.map { ProposalCardLine(.plain, "Fires \($0.description(in: home))") }
        card += endEvents.map {
            ProposalCardLine(.plain, "Ends with \($0.description(in: home)) — HomeKit restores the prior state")
        }
        card += capabilityNotes
        if executeOnce {
            card.append(ProposalCardLine(.plain, "Runs once — HomeKit disables the trigger after it fires."))
        }
        if let scene { card.append(ProposalCardLine(.plain, "Runs scene “\(scene.name)” when it fires.")) }
        if scene == nil {
            card.append(ProposalCardLine(
                .note, "⚠ Created without a scene — HomeKit cannot arm it; recreate with a scene to enable it later."
            ))
        }
        card.append(ProposalCardLine(
            .note, "⚠ Created disabled — arming it takes a separate set_trigger_state approval."
        ))

        return Plan(
            tool: "create_event_trigger",
            title: "Create event trigger “\(trimmed)”",
            summary: "Create event trigger “\(trimmed)” (disabled)",
            isDestructive: false,
            operations: [.addEventTrigger(
                homeId: home.id, name: trimmed, events: events, endEvents: endEvents,
                executeOnce: executeOnce, sceneId: scene?.id
            )],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .trigger, id: "", name: trimmed),
                op: .create,
                before: nil,
                after: "disabled"
            )],
            card: card
        )
    }

    /// Event-trigger editing (spec group 1): the event list is declarative —
    /// a full replacement, like set_scene_actions — with optional end-event,
    /// recurrence, execute-once, and scene changes. The create/arm firewall
    /// holds: the plan never touches isEnabled, and the card says so.
    static func updateEventTrigger(
        triggerId: String, events: [TriggerEventSpec], endEvents: [TriggerEventSpec]?,
        recurrences: [[String: Int]]?, executeOnce: Bool?, sceneId: String?, graph: HomeGraph
    ) throws -> Plan {
        let (home, trigger) = try self.trigger(id: triggerId, in: graph)
        guard case .event(let current) = trigger.detail else {
            throw PlannerError.invalidInput(
                "Trigger “\(trigger.name)” is a timer trigger — set_trigger_state moves its schedule; event triggers have no fire date."
            )
        }
        let currentEvents = current.events
        let capabilityNotes = try validate(events: events, home: home)
            + validate(events: endEvents ?? [], home: home)
        try validateEventTriggerRecurrences(recurrences)
        let newScene = try sceneReference(sceneId, in: home)

        // Diff the declarative list against the current events, matched by
        // canonical identity — the same name-or-UUID rule everywhere else, so
        // the card's diff, the executor, and the read-back agree.
        let currentKeys = currentEvents.map { $0.canonicalKey(in: home) }
        let targetKeys = events.map { $0.canonicalKey(in: home) }
        let removals = zip(currentEvents, currentKeys).filter { !targetKeys.contains($0.1) }
        let additions = zip(events, targetKeys).filter { !currentKeys.contains($0.1) }
        let eventsChanged = !additions.isEmpty || !removals.isEmpty
        let sceneChanged = sceneId.map { id in !trigger.linkedSceneIds.contains(id) } ?? false
        if !eventsChanged, !sceneChanged, endEvents == nil, recurrences == nil, executeOnce == nil {
            throw PlannerError.noChange("event trigger “\(trigger.name)” already watches exactly these events.")
        }

        let accessoryName = { (ref: HomeGraph.EventRef) -> String in
            ref.accessoryId.flatMap { accessory(id: $0, in: home)?.name } ?? ref.accessoryId ?? "an accessory"
        }
        var card: [ProposalCardLine] =
            removals.map {
                ProposalCardLine(.remove, "“\(trigger.name)” · remove event — \(describe(event: $0.0, accessoryName: accessoryName($0.0)))")
            }
            + additions.map {
                ProposalCardLine(.add, "“\(trigger.name)” · add event — fires \($0.0.description(in: home))")
            }
        if let endEvents {
            if endEvents.isEmpty {
                card.append(ProposalCardLine(.remove, "“\(trigger.name)” · end events cleared"))
            } else {
                card += endEvents.map {
                    ProposalCardLine(.plain, "“\(trigger.name)” · ends with \($0.description(in: home)) — HomeKit restores the prior state")
                }
            }
        }
        if let recurrences {
            let days = recurrences.compactMap { $0["weekday"] }.map(weekdayName)
            card.append(ProposalCardLine(
                .plain,
                days.isEmpty ? "Evaluated every day — recurrences cleared." : "Evaluated only on \(days.joined(separator: ", "))."
            ))
        }
        if let executeOnce {
            card.append(ProposalCardLine(
                .plain,
                executeOnce ? "Runs once — HomeKit disables the trigger after it fires." : "Repeats — the trigger keeps firing until deleted or disarmed."
            ))
        }
        if let newScene {
            card.append(ProposalCardLine(.plain, "Runs scene “\(newScene.name)” when it fires."))
        }
        if trigger.linkedSceneIds.isEmpty && sceneId == nil {
            card.append(ProposalCardLine(
                .note, "⚠ Runs no scene — HomeKit cannot arm it; pass sceneId to give it one."
            ))
        }
        card.append(ProposalCardLine(
            .note,
            "⚠ Editing does not change the trigger's armed state — it stays \(trigger.isEnabled ? "enabled" : "disabled")."
        ))

        let triggerRef = ProposalObjectRef(kind: .trigger, id: trigger.id, name: trigger.name)
        var entries: [ProposalDiffEntry] =
            removals.map {
                ProposalDiffEntry(
                    object: triggerRef, op: .removeMembers,
                    before: describe(event: $0.0, accessoryName: accessoryName($0.0)), after: nil
                )
            }
            + additions.map {
                ProposalDiffEntry(object: triggerRef, op: .addMembers, before: nil, after: $0.0.description(in: home))
            }
        if entries.isEmpty {
            // Field-only edits (executeOnce, recurrences, scene) still record
            // one entry so the diff is never empty.
            entries = [ProposalDiffEntry(object: triggerRef, op: .update, before: nil, after: "contents updated")]
        }

        return Plan(
            tool: "update_event_trigger",
            title: "Update event trigger “\(trigger.name)”",
            summary: "Update event trigger “\(trigger.name)” events (\(additions.count) added, \(removals.count) removed)",
            isDestructive: false,
            operations: [.updateEventTrigger(
                homeId: home.id, triggerId: trigger.id, events: events,
                endEvents: endEvents, recurrences: recurrences,
                executeOnce: executeOnce, sceneId: sceneId
            )],
            entries: entries,
            card: card
        )
    }

    static func setTriggerState(
        triggerId: String, enabled: Bool, fireDate: Date?, recurrence: [String: Int]?,
        graph: HomeGraph
    ) throws -> Plan {
        let (home, trigger) = try self.trigger(id: triggerId, in: graph)
        if trigger.isEnabled == enabled {
            throw PlannerError.noChange("trigger “\(trigger.name)” is already \(enabled ? "enabled" : "disabled").")
        }
        // HomeKit law: a trigger with no registered action sets has nothing
        // to run and cannot be enabled — the approval would always fail with
        // "No registered action sets for trigger". Say so at staging, where
        // the agent can act on it, instead of after a doomed approval.
        if enabled, trigger.linkedSceneIds.isEmpty {
            throw PlannerError.invalidInput(
                "Trigger “\(trigger.name)” runs no scene — HomeKit cannot enable an automation with no action sets. Delete it and recreate it with a scene (sceneId), then arm it."
            )
        }
        // Schedule updates ride the timer trigger only; an event trigger has
        // no fire date to update.
        if fireDate != nil || recurrence != nil, case .event = trigger.detail {
            throw PlannerError.invalidInput(
                "Trigger “\(trigger.name)” is an event trigger; fireDate and recurrence apply to timer triggers."
            )
        }

        let from = trigger.isEnabled ? "enabled" : "disabled"
        let to = enabled ? "enabled" : "disabled"
        var card: [ProposalCardLine] = [
            ProposalCardLine(enabled ? .add : .remove, "Trigger “\(trigger.name)” · \(from) → \(to)")
        ]
        if let fireDate, case .timer = trigger.detail {
            card.append(ProposalCardLine(.plain, timerLine(fireDate: fireDate, recurrence: recurrence ?? [:])))
        }
        if enabled {
            // The locked rule the card must make visible: this is the arm
            // step, always its own approval after the one that created it.
            card.append(ProposalCardLine(
                .note, "⚠ Arming an automation — it will run on its own once approved."
            ))
        }

        // Arming (or disarming) is always its own operation, and a timer
        // whose fire date moves rides the same proposal as a second op.
        var operations: [HomeKitOperation] = [
            .setTriggerEnabled(homeId: home.id, triggerId: trigger.id, enabled: enabled)
        ]
        if case .timer = trigger.detail, fireDate != nil || recurrence != nil {
            operations.append(.updateTimerTrigger(
                homeId: home.id, triggerId: trigger.id,
                fireDate: fireDate ?? timerFireDate(of: trigger),
                recurrence: recurrence ?? timerRecurrence(of: trigger)
            ))
        }

        return Plan(
            tool: "set_trigger_state",
            title: "\(enabled ? "Enable" : "Disable") trigger “\(trigger.name)”",
            summary: "\(enabled ? "Enable" : "Disable") trigger “\(trigger.name)”",
            isDestructive: false,
            operations: operations,
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .trigger, id: trigger.id, name: trigger.name),
                op: .update,
                before: from,
                after: to
            )],
            card: card
        )
    }

    static func deleteTrigger(triggerId: String, graph: HomeGraph) throws -> Plan {
        let (home, trigger) = try self.trigger(id: triggerId, in: graph)
        return Plan(
            tool: "delete_trigger",
            title: "Delete trigger “\(trigger.name)”",
            summary: "Delete trigger “\(trigger.name)”",
            isDestructive: true,
            operations: [.removeTrigger(homeId: home.id, triggerId: trigger.id)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .trigger, id: trigger.id, name: trigger.name),
                op: .delete,
                before: trigger.name,
                after: nil
            )],
            card: [
                ProposalCardLine(.remove, "Trigger “\(trigger.name)” · deleted"),
                // Spec risk: a silently-disabled automation looks healthy
                // until it fails to fire. Deletion is louder, but the card
                // still says what stops existing.
                ProposalCardLine(.plain, "The automation stops firing immediately — visible to the Home app and Siri."),
            ]
        )
    }
}
