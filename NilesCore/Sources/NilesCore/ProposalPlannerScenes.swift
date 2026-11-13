import Foundation

extension ProposalPlanner {
    // MARK: - Scenes

    static func createScene(homeId: String, name: String, actions: [SceneActionSpec], graph: HomeGraph) throws -> Plan {
        let trimmed = try requiredHomeKitName(name, kind: "scene")
        let home = try self.home(id: homeId, in: graph)
        try rejectDuplicate(kind: "scene", name: trimmed, in: home.scenes.map(\.name), homeName: home.name)
        let capabilityNotes = try validate(accessories: actions, home: home)

        let actionNoun = actions.count == 1 ? "action" : "actions"
        var card: [ProposalCardLine] = [
            ProposalCardLine(.add, "Scene “\(trimmed)” · created with \(actions.count) \(actionNoun)")
        ]
        card += actions.map { ProposalCardLine(.add, describe(spec: $0, home: home)) }
        card += capabilityNotes
        // Scope note: the card preempts the "did it run?" question —
        // running the scene is a separate approval (execute_scene).
        card.append(ProposalCardLine(.note, "⚠ To run this scene later, use execute_scene after approval."))

        return Plan(
            tool: "create_scene",
            title: "Create scene “\(trimmed)”",
            summary: "Create scene “\(trimmed)” with \(actions.count) \(actionNoun)",
            isDestructive: false,
            operations: [.addActionSet(homeId: home.id, name: trimmed, actions: actions)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .scene, id: "", name: trimmed),
                op: .create,
                before: nil,
                after: "\(actions.count) \(actionNoun)"
            )],
            card: card
        )
    }

    static func setSceneActions(sceneId: String, actions: [SceneActionSpec], graph: HomeGraph) throws -> Plan {
        let (home, scene) = try self.scene(id: sceneId, in: graph)
        let capabilityNotes = try validate(accessories: actions, home: home)

        let currentKeys = scene.actions.map(SceneActionKey.init(action:))
        let targetKeys = actions.map(SceneActionKey.init(spec:))
        let additions = actions.filter { spec in !currentKeys.contains(SceneActionKey(spec: spec)) }
        let removals = scene.actions.filter { action in !targetKeys.contains(SceneActionKey(action: action)) }
        if additions.isEmpty && removals.isEmpty {
            throw PlannerError.noChange("scene “\(scene.name)” already has exactly these actions.")
        }

        let sceneRef = ProposalObjectRef(kind: .scene, id: scene.id, name: scene.name)
        let entries: [ProposalDiffEntry] =
            removals.map { action in
                ProposalDiffEntry(
                    object: sceneRef, op: .removeMembers,
                    before: describe(action: action, home: home), after: nil
                )
            }
            + additions.map { spec in
                ProposalDiffEntry(
                    object: sceneRef, op: .addMembers,
                    before: nil, after: describe(spec: spec, home: home)
                )
            }

        var card: [ProposalCardLine] =
            removals.map { action in
                ProposalCardLine(.remove, "“\(scene.name)” · remove action \(describe(action: action, home: home))")
            }
            + additions.map { spec in
                ProposalCardLine(.add, "“\(scene.name)” · add action \(describe(spec: spec, home: home))")
            }
        let unchanged = scene.actions.count - removals.count
        if unchanged > 0 {
            let noun = unchanged == 1 ? "action" : "actions"
            card.append(ProposalCardLine(.plain, "\(unchanged) existing \(noun) unchanged."))
        }
        card += capabilityNotes

        return Plan(
            tool: "set_scene_actions",
            title: "Update scene “\(scene.name)”",
            summary: "Update scene “\(scene.name)” actions (\(additions.count) added, \(removals.count) removed)",
            isDestructive: false,
            operations: [.setSceneActions(
                homeId: home.id, sceneId: scene.id,
                add: additions, remove: removals.map(SceneActionKey.init(action:))
            )],
            entries: entries,
            card: card
        )
    }

    static func renameScene(sceneId: String, name: String, graph: HomeGraph) throws -> Plan {
        let (home, scene) = try self.scene(id: sceneId, in: graph)
        let trimmed = try requiredHomeKitName(name, kind: "scene", subject: "Scene “\(scene.name)”")
        if scene.name.caseInsensitiveCompare(trimmed) == .orderedSame {
            throw PlannerError.noChange("scene “\(scene.name)” is already named “\(trimmed)”.")
        }
        // Scene names are unique across all homes (HomeKit's rule); the new
        // name cannot collide with another scene — this one included.
        let otherScenes = graph.homes.flatMap(\.scenes).filter { $0.id != scene.id }
        try rejectDuplicate(kind: "scene", name: trimmed, in: otherScenes.map(\.name), homeName: home.name)
        return Plan(
            tool: "rename_scene",
            title: "Rename scene “\(scene.name)”",
            summary: "Rename scene “\(scene.name)” to “\(trimmed)”",
            isDestructive: false,
            operations: [.renameActionSet(homeId: home.id, sceneId: scene.id, to: trimmed)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .scene, id: scene.id, name: scene.name),
                op: .rename,
                before: scene.name,
                after: trimmed
            )],
            card: [ProposalCardLine(.plain, "Scene “\(scene.name)” → “\(trimmed)”")]
        )
    }

    /// Spec (destructive staging): the card lists every trigger that links
    /// the scene — a dangling automation is the silent blast radius of a
    /// scene delete — plus the immediate-stop explainer. The scene's saved
    /// actions are deliberately absent (Matthew, 2026-11-13): they are the
    /// scene's CONTENT — what it did when it ran — not an effect of the
    /// deletion, and reading them as change rows made a deletion look like
    /// a device write. The `deleteLinkedTriggers` flag is the spec's
    /// "delete trigger too / keep trigger" offer, and the card says which
    /// way it goes.
    static func deleteScene(
        sceneId: String, deleteLinkedTriggers: Bool, graph: HomeGraph
    ) throws -> Plan {
        let (home, scene) = try self.scene(id: sceneId, in: graph)
        let linked = home.triggers.filter { $0.linkedSceneIds.contains(scene.id) }

        var operations: [HomeKitOperation] = [.removeActionSet(homeId: home.id, sceneId: scene.id)]
        if deleteLinkedTriggers {
            operations += linked.map { .removeTrigger(homeId: home.id, triggerId: $0.id) }
        }

        var card: [ProposalCardLine] = [ProposalCardLine(.remove, "Scene “\(scene.name)” · deleted")]
        // No per-action rows here: the scene's saved actions describe what
        // the scene did when it ran — content, not a deletion effect (see
        // the doc comment above).
        for trigger in linked {
            if deleteLinkedTriggers {
                card.append(ProposalCardLine(.remove, "Trigger “\(trigger.name)” · deleted too — it runs this scene"))
            } else {
                card.append(ProposalCardLine(
                    .note,
                    "⚠ Trigger “\(trigger.name)” no longer runs anything — its scene is gone. Pass deleteLinkedTriggers to delete it too."
                ))
            }
        }
        card.append(ProposalCardLine(
            .plain,
            "The scene stops working immediately — visible to the Home app and Siri."
        ))

        let entries: [ProposalDiffEntry] = [ProposalDiffEntry(
            object: ProposalObjectRef(kind: .scene, id: scene.id, name: scene.name),
            op: .delete,
            before: scene.name,
            after: nil
        )] + (deleteLinkedTriggers ? linked.map { trigger in
            ProposalDiffEntry(
                object: ProposalObjectRef(kind: .trigger, id: trigger.id, name: trigger.name),
                op: .delete,
                before: trigger.name,
                after: nil
            )
        } : [])

        let triggerNoun = linked.count == 1 ? "1 trigger" : "\(linked.count) triggers"
        let title = deleteLinkedTriggers && !linked.isEmpty
            ? "Delete scene “\(scene.name)” and \(triggerNoun)"
            : "Delete scene “\(scene.name)”"
        return Plan(
            tool: "delete_scene",
            title: title,
            summary: "Delete scene “\(scene.name)”" + (deleteLinkedTriggers && !linked.isEmpty ? " with \(triggerNoun)" : ""),
            isDestructive: true,
            operations: operations,
            entries: entries,
            card: card
        )
    }

    static func executeScene(sceneId: String, graph: HomeGraph) throws -> Plan {
        let (home, scene) = try self.scene(id: sceneId, in: graph)
        if scene.actions.isEmpty {
            throw PlannerError.invalidInput(
                "Scene “\(scene.name)” has no actions — HomeKit refuses to execute an empty scene."
            )
        }
        let actionNoun = scene.actions.count == 1 ? "action" : "actions"
        var card: [ProposalCardLine] = [
            ProposalCardLine(.add, "Scene “\(scene.name)” · runs on approval")
        ]
        card += scene.actions.map { ProposalCardLine(.plain, describe(action: $0, home: home)) }
        card.append(ProposalCardLine(
            .note,
            "⚠ Device-immediate — every action above applies to the devices the moment this is approved."
        ))
        return Plan(
            tool: "execute_scene",
            title: "Run scene “\(scene.name)”",
            summary: "Run scene “\(scene.name)” now (\(scene.actions.count) \(actionNoun))",
            isDestructive: false,
            operations: [.executeActionSet(homeId: home.id, sceneId: scene.id)],
            entries: [ProposalDiffEntry(
                object: ProposalObjectRef(kind: .scene, id: scene.id, name: scene.name),
                op: .update,
                before: "not running",
                after: "runs on approval"
            )],
            card: card
        )
    }
}
