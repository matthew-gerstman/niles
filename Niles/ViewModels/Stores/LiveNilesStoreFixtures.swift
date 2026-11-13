import Foundation
import NilesCore
import OSLog

/// Simulator QA fixtures, split out of the composition root in cleanup W3.
/// `LiveNilesStore` keeps the same API surface — these are its methods, in
/// an extension over the root so they can read the coordinator, the queue
/// store, and the shared poll fan-out.
extension LiveNilesStore {

    // MARK: - Simulator QA fixtures

    /// Screenshots and device QA: with a `-UISeedQueue <fixture>` launch
    /// argument, stages real proposals through the real pipeline (the same
    /// registry the transport serves) so the Queue renders live states
    /// without an MCP client — and, for the conflict fixture, diverges the
    /// fake home and performs the Undo tap so the row shows the typed
    /// divergence error. No-op without the argument.
    func seedQueueFixtureIfRequested() async {
        guard let fixture = LaunchArguments.uiSeedQueue else { return }
        guard let store = coordinator.proposalStore else {
            logger.error("Seed fixture requested but no proposal store is running")
            return
        }
        // The app target does not link MCP, so fixtures stage hand-built
        // Plans directly. Operations stay real — approve/undo exercise the
        // same execution and revert-derivation paths as agent-staged writes.
        func room(_ id: String, _ name: String?) -> ProposalObjectRef {
            ProposalObjectRef(kind: .room, id: id, name: name)
        }
        func stage(_ plan: Plan) async -> String? {
            _ = await store.stage(plan: plan)
            await refresh()
            return queue.pendingProposals.first { $0.tool == plan.tool }?.id
        }
        func createRoomPlan() -> Plan {
            Plan(
                tool: "create_room",
                title: "Create room Studio",
                summary: "Adds the Studio room to the home.",
                isDestructive: false,
                operations: [.addRoom(homeId: "home-1", name: "Studio")],
                entries: [.init(object: room("", "Studio"), op: .create, before: nil, after: "Studio")],
                card: [.init(.add, "Add room Studio")]
            )
        }

        switch fixture {
        case "pending":
            _ = await stage(createRoomPlan())
            _ = await stage(Plan(
                tool: "rename_room",
                title: "Rename room to Cookery",
                summary: "Renames room-2 to Cookery.",
                isDestructive: false,
                operations: [.renameRoom(homeId: "home-1", roomId: "room-2", to: "Cookery")],
                entries: [.init(object: room("room-2", "Cookery"), op: .rename, before: nil, after: "Cookery")],
                card: [.init(.plain, "Rename room to Cookery")]
            ))

        case "destructive":
            _ = await stage(createRoomPlan())
            _ = await stage(Plan(
                tool: "delete_room",
                title: "Delete room",
                summary: "Removes room-3 and its accessory assignments.",
                isDestructive: true,
                operations: [.removeRoom(homeId: "home-1", roomId: "room-3")],
                entries: [.init(object: room("room-3", nil), op: .delete, before: nil, after: nil)],
                card: [.init(.remove, "Delete room-3"), .init(.note, "Accessories in this room become unassigned.")]
            ))

        case "undo":
            guard let id = await stage(createRoomPlan()) else { return }
            await queue.approveAndWait(id)

        case "evidence":
            // Read-back QA: friendly names in claims and observations, one
            // unconfirmed check, and a vanished object falling back to its
            // raw id with a not-found explanation. The batch adds a room,
            // updates the Downstairs zone, then deletes that zone — so the
            // zone update's read-back runs after the delete removed it.
            _ = await stage(Plan(
                tool: "update_zone",
                title: "Create Studio, fill Downstairs, delete the zone",
                summary: "Adds room Studio, moves Office into Downstairs, then deletes the zone.",
                isDestructive: true,
                operations: [
                    .addRoom(homeId: "home-1", name: "Studio"),
                    .setZoneRooms(homeId: "home-1", zoneId: "zone-1", addRoomIds: ["room-3"], removeRoomIds: []),
                    .removeZone(homeId: "home-1", zoneId: "zone-1"),
                ],
                entries: [
                    .init(object: ProposalObjectRef(kind: .room, id: "", name: "Studio"), op: .create, before: nil, after: "Studio"),
                    .init(object: ProposalObjectRef(kind: .zone, id: "zone-1", name: "Downstairs"), op: .addMembers, before: nil, after: "Office"),
                    .init(object: ProposalObjectRef(kind: .zone, id: "zone-1", name: "Downstairs"), op: .delete, before: "Downstairs", after: nil),
                ],
                card: [
                    .init(.add, "Add room Studio"),
                    .init(.plain, "Move Office into zone Downstairs"),
                    .init(.remove, "Delete zone Downstairs"),
                ]
            ))
            let evidenceProposalId = queue.pendingProposals.first { $0.tool == "update_zone" }?.id
            if let evidenceProposalId {
                await queue.approveAndWait(evidenceProposalId)
            }

        case "moves":
            // The move-echo QA fixture (Nov 13): a mixed batch over the
            // demo home — two accessory moves plus a scene edit. The
            // moves' detail rows are pure echoes of their headers; the
            // scene edit's row IS its payload and must keep rendering.
            // Staged through the real batch path (`stage_batch`), so the
            // card is exactly what an agent's batch produces. Never
            // approved here — the fixture only stages for capture.
            do {
                _ = try await store.stageBatch([
                    BatchOperation(tool: "assign_accessory_to_room", arguments: [
                        "accessoryId": .string("acc-1"), "roomId": .string("room-2"),
                    ]),
                    BatchOperation(tool: "assign_accessory_to_room", arguments: [
                        "accessoryId": .string("acc-6"), "roomId": .string("room-1"),
                    ]),
                    BatchOperation(tool: "set_scene_actions", arguments: [
                        "sceneId": .string("scene-1"),
                        "actions": .array([.object([
                            "accessoryId": .string("acc-1"),
                            "characteristic": .string("Brightness"),
                            "value": .int(30),
                        ])]),
                    ]),
                ])
                await refresh()
            } catch {
                logger.error("Moves fixture staging failed: \(String(describing: error))")
            }

        case "conflict":
            guard let id = await stage(createRoomPlan()) else { return }
            await queue.approveAndWait(id)
            // Diverge the home out-of-band — the revert expects the created
            // room to still exist, so removing it directly is exactly the
            // "the world moved" case the conflict check exists for.
            do {
                let graph = try await store.homeKit.snapshot()
                let home = graph.homes.first
                guard let room = home?.rooms.first(where: { $0.name == "Studio" }) else { return }
                _ = try await store.homeKit.perform(.removeRoom(homeId: home?.id ?? "", roomId: room.id))
                // The Undo tap, performed exactly as the row's button does it.
                await queue.undoAndWait(id)
            } catch {
                logger.error("Conflict fixture diverge failed: \(String(describing: error))")
            }

        case "in_flight":
            // Screenshot fixture: a swipe decision frozen mid-pipeline — the
            // row is out of the Queue and renders on Activity as processing
            // (Denying…/Executing…). The chip is planted directly because
            // the real pipeline settles in milliseconds on the fake home,
            // too fast to capture; it renders the exact state a real swipe
            // shows while the pipeline runs.
            guard let id = await stage(createRoomPlan()) else { return }
            queue.plantInFlightDecision(id)

        case "approved_in_flight":
            // Screenshot fixture: store-driven in-flight — the proposal the
            // pipeline has decided and is executing, its persisted state
            // `approved`, with no local swipe marker. This is the shape a
            // poll or a relaunch mid-execution surfaces: it renders in
            // Activity as Executing… and never in the Queue. Planted
            // directly (and frozen against the poll) for the same
            // too-fast-to-capture reason as `in_flight`.
            guard let id = await stage(createRoomPlan()) else { return }
            guard let frozen = queue.plantApprovedInFlight(id) else { return }
            // The first refresh after start() consumes a staged proposal
            // as a launch-time existing row — no arrival event — so the
            // Activity side would render nothing. Record the staged
            // event the pipeline would have logged for it.
            await queue.appendActivity(
                .staged,
                proposalId: id,
                title: frozen.title,
                agentName: agentNamesByProposal[id]
            )

        case "deny_in_flight":
            // Same frozen mid-pipeline state, denying side: the Activity
            // processing row must read Denying… while the pipeline runs.
            guard let id = await stage(createRoomPlan()) else { return }
            queue.plantInFlightDecision(id, .denying)

        case "batch4":
            // Screenshot fixture: a 4-op batch (scene create, device-immediate
            // brightness write, identify with an unverifiable-support warning,
            // scene rename) in exactly the card format merge() persists —
            // banners included — so the detail sheet's group parsing renders
            // against real persisted shapes. Capture with
            // `-UIProposalDetail stage_batch`.
            _ = await stage(Plan(
                tool: ProposalStore.batchToolName,
                title: "Batch: 4 changes",
                summary: "Batch: 4 changes — 1 scene create, 1 device write, 1 identify, 1 scene rename.",
                isDestructive: false,
                operations: [],
                entries: [],
                card: [
                    .init(.note, "— Operation 1 of 4: Create scene “QA Design Round Scene” —"),
                    .init(.add, "Scene “QA Design Round Scene” · created with 1 action"),
                    .init(.add, "Living Room Accent Lights: Power State → 1"),
                    .init(.note, "⚠ To run this scene later, use execute_scene after approval."),
                    .init(.note, "— Operation 2 of 4: Set “Living Room Accent Lights” Brightness to 50 —"),
                    .init(.add, "Living Room Accent Lights: Brightness 73 → 50"),
                    .init(.note, "⚠ Device-immediate — the value applies to the device the moment this is approved."),
                    .init(.note, "— Operation 3 of 4: Identify accessory “Living Room Accent Lights” —"),
                    .init(.add, "Accessory “Living Room Accent Lights” · identified (flash/beep)"),
                    .init(.note, "⚠ Could not verify identify support — “Living Room Accent Lights”'s capability data is unavailable; approval may still fail at execution."),
                    .init(.note, "— Operation 4 of 4: Rename scene “QA E2E Single A” —"),
                    .init(.add, "Scene “QA E2E Single A” → “QA Design Round Renamed”"),
                ]
            ))

        case "decision_failed":
            // Screenshot fixture: a failed decision — the row is back in
            // the Queue with its typed error note and re-enabled swipes.
            // Planted like in_flight; the wording is the real one.
            guard let id = await stage(createRoomPlan()) else { return }
            queue.plantDecisionFailure(id, approve: true, reason: "the proposal was already decided")

        default:
            logger.error("Unknown -UISeedQueue fixture: \(fixture, privacy: .public)")
        }
        await refresh()
    }

    /// Relaunch QA fixture (`-UIProposalsFixture seed`): seeds proposal
    /// state whose survival the NEXT launch must show, then the app is
    /// terminated and relaunched plain. Stages four proposals through the
    /// real store — a normal staged one, one whose target room never existed
    /// (launch revalidation must flag it), one already past its TTL staged
    /// on disk (the load-time sweep must expire it, and the relaunch records
    /// the timestamped event), and one that is approved and executed (its
    /// activity history and revert plan must survive, so the relaunched
    /// Activity still shows the card and the row still offers Undo).
    /// No-op without the argument; any mode but `seed` is logged and ignored.
    func seedProposalsFixtureIfRequested() async {
        guard let mode = LaunchArguments.uiProposalsFixture else { return }
        guard mode == "seed" else {
            logger.error("Unknown -UIProposalsFixture mode: \(mode, privacy: .public)")
            return
        }
        guard let store = coordinator.proposalStore else {
            logger.error("Proposals fixture requested but no proposal store is running")
            return
        }
        func room(_ id: String, _ name: String?) -> ProposalObjectRef {
            ProposalObjectRef(kind: .room, id: id, name: name)
        }
        // 1. A normal staged proposal — survives relaunch as staged.
        _ = await store.stage(plan: Plan(
            tool: "create_room",
            title: "Create room Studio",
            summary: "Adds the Studio room to the home.",
            isDestructive: false,
            operations: [.addRoom(homeId: "home-1", name: "Studio")],
            entries: [.init(object: room("", "Studio"), op: .create, before: nil, after: "Studio")],
            card: [.init(.add, "Add room Studio")]
        ))
        // 2. A staged proposal whose target never existed: launch
        //    revalidation flags it and the Queue keeps showing it.
        _ = await store.stage(plan: Plan(
            tool: "rename_room",
            title: "Rename room to Attic",
            summary: "Renames room-99 to Attic.",
            isDestructive: false,
            operations: [.renameRoom(homeId: "home-1", roomId: "room-99", to: "Attic")],
            entries: [.init(object: room("room-99", "Attic"), op: .rename, before: nil, after: "Attic")],
            card: [.init(.plain, "Rename room to Attic")]
        ))
        // 3. Staged with an expiry seconds away: run 1 terminates long
        //    before it passes, so the proposal is STAGED on disk and past
        //    its TTL at relaunch — the load-time sweep's exact input.
        _ = await store.stage(
            plan: Plan(
                tool: "set_zone_rooms",
                title: "Move Office into Upstairs",
                summary: "Adds room-3 to zone-1.",
                isDestructive: false,
                operations: [.setZoneRooms(homeId: "home-1", zoneId: "zone-1", addRoomIds: ["room-3"], removeRoomIds: [])],
                entries: [.init(object: ProposalObjectRef(kind: .zone, id: "zone-1", name: "Upstairs"), op: .addMembers, before: nil, after: "Office")],
                card: [.init(.plain, "Move Office into Upstairs")]
            ),
            expiresAt: Date().addingTimeInterval(90)
        )
        // 4. Approved and executed: decided history plus a paired revert
        //    plan — the relaunched Activity card and the row's Undo
        //    affordance both come back from disk.
        let workshop = await store.stage(plan: Plan(
            tool: "create_room",
            title: "Create room Workshop",
            summary: "Adds the Workshop room to the home.",
            isDestructive: false,
            operations: [.addRoom(homeId: "home-1", name: "Workshop")],
            entries: [.init(object: room("", "Workshop"), op: .create, before: nil, after: "Workshop")],
            card: [.init(.add, "Add room Workshop")]
        ))
        // Refresh before the approval: `pendingProposals` reads the UI
        // array, which a stale refresh left empty — deciding on a stale
        // lookup would silently skip the execution this fixture exists for.
        await refresh()
        if workshop.state == .staged {
            await queue.approveAndWait(workshop.id)
        }
        await refresh()
    }
}
