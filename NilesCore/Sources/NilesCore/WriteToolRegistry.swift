import Foundation
import MCP

/// The mutating MCP tools: twenty-six declarative write tools plus the
/// `get_proposal` poll. None of them touches HomeKit — a call plans the
/// request against the current graph and stages exactly one proposal
/// (spec: "one agent request is always exactly one approval card"); the
/// human approves or denies on the device, and the agent reads the outcome
/// back through `get_proposal`.
///
/// The transport layer composes this registry alongside `ReadToolRegistry`.
public struct WriteToolRegistry: Sendable {
    private let store: ProposalStore

    public init(store: ProposalStore) {
        self.store = store
    }

    /// The write tools, in listing order.
    public var tools: [Tool] { Self.toolDefinitions }

    /// The names `call` answers: the write tools plus `get_proposal`.
    public var toolNames: Set<String> { Set(Self.toolDefinitions.map(\.name)) }

    /// The full registry tool definitions — the source of truth the agent
    /// toolset generator projects into session tools.
    public var toolDefinitions: [Tool] { Self.toolDefinitions }

    /// Answers one `tools/call` for a write tool or `get_proposal`. Every
    /// failure — unknown tool, invalid arguments, rejected validation — is an
    /// `isError` result naming what to fix, never a thrown error the agent
    /// cannot see.
    public func call(name: String, arguments: [String: Value]? = nil) async -> CallTool.Result {
        do {
            if name == "get_proposal" {
                guard let id = arguments?["proposalId"]?.stringValue else {
                    throw ProposalStoreError.invalidArguments("Missing required argument “proposalId”.")
                }
                let proposal = try await store.proposal(id: id)
                return try Self.result(proposal, summary: Self.statusSummary(for: proposal))
            }
            // The MCP boundary for the staging pipeline: wire arguments
            // decode once here, and everything downstream of `stage` —
            // planner, store, app layer — speaks `ToolArgument` only.
            let proposal = try await store.stage(
                tool: name,
                arguments: arguments?.compactMapValues(ToolArgument.init)
            )
            return try Self.result(proposal, summary: Self.stagedSummary(for: proposal))
        } catch {
            return Self.errorResult(Self.message(for: error, tool: name))
        }
    }

    // MARK: - Shared descriptions (art_34OYtrUm: one text per tool, both projections)

    /// Plain-language descriptions for the tools both consumers see — the
    /// agent surface projects these six plus the two reads held in
    /// `ReadToolRegistry`. The MCP listing appends `stagingSuffix` so each
    /// write tool states the approval contract; the on-device agent's
    /// session instructions state it once instead, so the agent consumes
    /// the plain text verbatim. Concept-oriented: payload vocabulary that
    /// differs between the surfaces (group members as service ids for MCP
    /// clients, accessory ids for the agent) is described on each schema's
    /// own arguments, never in the shared text.
    static let createDescription =
        "Create an object: a room, zone, scene, group, or automation (timer or event trigger). Payload depends on kind — groups take a member list, scenes take actions (characteristic writes — Niles never executes scenes), timers take a fire date and optional recurrence, event triggers take events. Automations are created DISABLED — arming one requires a separate set_trigger_state approval. Zone names are unique per home."
    static let updateDescription =
        "Replace an object's complete contents — declarative: anything absent from the list is removed. Groups take members, zones take rooms, scenes take actions (characteristic writes), and event triggers take events (plus optional endEvents, recurrences, executeOnce, or a new sceneId). Timer triggers have no event list — set_trigger_state moves their schedule, and arming is always its own proposal. Editing never changes a trigger's armed state."
    static let renameDescription =
        "Rename a room, zone, scene, accessory group, or accessory by id — resolve the id with search or get_details first."
    static let deleteDescription =
        "DESTRUCTIVE. Delete an object by id: a room, zone, scene, accessory group, accessory, or automation trigger. Per-type consequences — where a room's accessories go, which triggers a deleted scene leaves behind — appear on the review card; for a scene, pass deleteLinkedTriggers to delete those too."
    static let getProposalDescription =
        "Read one proposal's current state: staged/approved/executed/denied/expired/failed, its diff, the recorded evidence after execution, or the error if execution failed. Poll after every write to learn the outcome."
    static let assignAccessoryToRoomDescription = "Move an accessory to a different room."

    /// The staging contract carried on every MCP write listing. The agent
    /// catalog strips exactly this suffix to recover the plain text.
    static let stagingSuffix =
        " STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards."

    // MARK: - Tool definitions

    private static let toolDefinitions: [Tool] = [
        // Unified verbs (Blueprint art_34OYtrUm, write layer): one entry
        // point per operation, dispatched by id to the same staged-proposal
        // code paths the per-type tools use. Additive — the per-type tools
        // below stay registered and functional, marked DEPRECATED.
        Tool(
            name: "rename",
            description: Self.renameDescription + Self.stagingSuffix,
            inputSchema: objectSchema(
                [
                    "entityId": stringProperty("The object to rename (from search or get_details)."),
                    "newName": stringProperty("The object's new name."),
                ],
                required: ["entityId", "newName"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "delete",
            description: Self.deleteDescription + Self.stagingSuffix,
            inputSchema: objectSchema(
                [
                    "entityId": stringProperty("The object to delete (from search or get_details)."),
                    "deleteLinkedTriggers": .object([
                        "type": .string("boolean"),
                        "description": .string("When deleting a scene: true also deletes every trigger that runs it; omit or false keeps them (they run nothing)."),
                    ]),
                ],
                required: ["entityId"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false, destructiveHint: true)
        ),
        Tool(
            name: "create",
            description: Self.createDescription + Self.stagingSuffix,
            inputSchema: objectSchema(
                [
                    "kind": .object([
                        "type": .string("string"),
                        "description": .string("What to create: \"room\", \"zone\", \"scene\", \"group\", \"timer\" (timer automation), or \"event\" (event automation)."),
                    ]),
                    "homeId": stringProperty("The home to create the object in (from get_homes)."),
                    "name": stringProperty("The new object's name."),
                    "actions": sceneActionsProperty,
                    "serviceIds": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Groups only: the services to group (from get_service_groups); omit for an empty group."),
                    ]),
                    "fireDate": stringProperty("Timers only: first fire time, ISO-8601, e.g. 2026-11-09T07:30:00Z."),
                    "recurrence": .object([
                        "type": .string("object"),
                        "description": .string("Timers only: optional repeat rule as date components, e.g. {\"weekday\": 1, \"hour\": 7, \"minute\": 30}. Omit for a one-shot trigger."),
                    ]),
                    "events": triggerEventsProperty("Event automations only: every event that can activate the trigger."),
                    "endEvents": triggerEventsProperty(
                        "Event automations only: optional events that end the effect and restore the prior state — e.g. end events on the same characteristics the trigger raised."
                    ),
                    "executeOnce": .object([
                        "type": .string("boolean"),
                        "description": .string("Event automations only: true runs the trigger once and HomeKit disables it afterwards."),
                    ]),
                    "sceneId": stringProperty("Timers and event automations only: optional scene the trigger runs when it fires (from get_scenes)."),
                ],
                required: ["kind", "homeId", "name"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "update",
            description: Self.updateDescription + Self.stagingSuffix,
            inputSchema: objectSchema(
                [
                    "entityId": stringProperty("The group, zone, scene, or event trigger to update (from search or get_details)."),
                    "members": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Groups only: every service the group should contain (from get_service_groups)."),
                    ]),
                    "rooms": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Zones only: every room the zone should contain (from get_rooms)."),
                    ]),
                    "actions": sceneActionsProperty,
                    "events": triggerEventsProperty("Event triggers only: the full replacement event list that can activate the trigger."),
                    "endEvents": triggerEventsProperty(
                        "Event triggers only: optional replacement end events; omit to leave them unchanged, pass [] to clear."
                    ),
                    "recurrences": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("object")]),
                        "description": .string(
                            "Event triggers only: optional days of the week when the trigger is evaluated, e.g. [{\"weekday\": 1}] (1 = Sunday). Omit to leave unchanged; pass [] to clear."
                        ),
                    ]),
                    "executeOnce": .object([
                        "type": .string("boolean"),
                        "description": .string("Event triggers only: true runs the trigger once and HomeKit disables it afterwards; omit to leave unchanged."),
                    ]),
                    "sceneId": stringProperty(
                        "Event triggers only: optional scene the trigger runs when it fires (from get_scenes); re-points the trigger when passed, leaves the current scene untouched when omitted."
                    ),
                ],
                required: ["entityId"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "create_room",
            description: "DEPRECATED — prefer create(kind: \"room\", homeId, name). Create a room in a home. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles on the iPhone. Returns the proposal id immediately; poll get_proposal to learn whether it was approved.",
            inputSchema: objectSchema(
                [
                    "homeId": stringProperty("The home to create the room in (from get_homes)."),
                    "name": stringProperty("The new room's name."),
                ],
                required: ["homeId", "name"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "rename_room",
            description: "DEPRECATED — prefer rename(entityId, newName). Rename a room. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                [
                    "roomId": stringProperty("The room to rename (from get_rooms)."),
                    "name": stringProperty("The room's new name."),
                ],
                required: ["roomId", "name"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "delete_room",
            description: "DEPRECATED — prefer delete(entityId). Delete a room. Its accessories move to the default room (HomeKit behavior; the review card says which). DESTRUCTIVE. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                ["roomId": stringProperty("The room to delete (from get_rooms).")],
                required: ["roomId"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false, destructiveHint: true)
        ),
        Tool(
            name: "set_zone_rooms",
            description: "DEPRECATED — prefer update(entityId, rooms:). Set a zone's complete room membership — declarative: pass every room the zone should contain; rooms absent from the list are removed, and the review card shows both. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                [
                    "zoneId": stringProperty("The zone to update (from get_zones)."),
                    "roomIds": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Every room the zone should contain (from get_rooms)."),
                    ]),
                ],
                required: ["zoneId", "roomIds"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "create_zone",
            description: "DEPRECATED — prefer create(kind: \"zone\", homeId, name). Create an empty zone (e.g. 'Upstairs'); add rooms with set_zone_rooms. Zone names are unique within a home. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                [
                    "homeId": stringProperty("The home to create the zone in (from get_homes)."),
                    "name": stringProperty("The new zone's name."),
                ],
                required: ["homeId", "name"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "rename_zone",
            description: "DEPRECATED — prefer rename(entityId, newName). Rename a zone. Its rooms are unaffected. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                [
                    "zoneId": stringProperty("The zone to rename (from get_zones)."),
                    "name": stringProperty("The zone's new name."),
                ],
                required: ["zoneId", "name"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "delete_zone",
            description: "DEPRECATED — prefer delete(entityId). Delete a zone. Its rooms survive untouched — only the grouping is removed (the review card says which rooms were grouped). DESTRUCTIVE. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                ["zoneId": stringProperty("The zone to delete (from get_zones).")],
                required: ["zoneId"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false, destructiveHint: true)
        ),
        Tool(
            name: "create_scene",
            description: "DEPRECATED — prefer create(kind: \"scene\", homeId, name, actions:). Create a scene (HomeKit action set) whose actions are characteristic writes. Niles stages scenes; it never executes them — running the scene stays in the Home app or Siri. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                [
                    "homeId": stringProperty("The home to create the scene in (from get_homes)."),
                    "name": stringProperty("The new scene's name."),
                    "actions": sceneActionsProperty,
                ],
                required: ["homeId", "name", "actions"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "set_scene_actions",
            description: "DEPRECATED — prefer update(entityId, actions:). Set a scene's complete action list — declarative: actions absent from the list are removed. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                [
                    "sceneId": stringProperty("The scene to update (from get_scenes)."),
                    "actions": sceneActionsProperty,
                ],
                required: ["sceneId", "actions"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "rename_scene",
            description: "DEPRECATED — prefer rename(entityId, newName). Rename a scene (HomeKit action set). Scene names are unique across all homes. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                [
                    "sceneId": stringProperty("The scene to rename (from get_scenes)."),
                    "name": stringProperty("The scene's new name."),
                ],
                required: ["sceneId", "name"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "delete_scene",
            description: "DEPRECATED — prefer delete(entityId). Delete a scene. Any trigger that runs it keeps existing but no longer runs anything — the review card names every linked trigger; pass deleteLinkedTriggers to delete those too. DESTRUCTIVE. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                [
                    "sceneId": stringProperty("The scene to delete (from get_scenes)."),
                    "deleteLinkedTriggers": .object([
                        "type": .string("boolean"),
                        "description": .string("true also deletes every trigger that runs this scene; omit or false keeps them (they run nothing)."),
                    ]),
                ],
                required: ["sceneId"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false, destructiveHint: true)
        ),
        Tool(
            name: "execute_scene",
            description: "Run a scene NOW — every action applies to the devices as soon as a human approves it (device-immediate; the review card says so). HomeKit refuses to execute an empty scene. STAGES A PROPOSAL — nothing runs until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                ["sceneId": stringProperty("The scene to run (from get_scenes).")],
                required: ["sceneId"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "write_characteristic",
            description: "Write a value to one of an accessory's characteristics NOW — the change applies to the device as soon as a human approves it (device-immediate; the review card shows the current and target values). The target matches by friendly name or type UUID, e.g. On, Brightness, or 00000008-0000-1000-8000-0026BB765291. The value must fit the characteristic's declared metadata (type and range) or staging rejects it. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                [
                    "accessoryId": stringProperty("The accessory to write (from get_rooms)."),
                    "service": stringProperty("Optional service name or type; defaults to the first service carrying the characteristic."),
                    "characteristic": stringProperty("The characteristic to write, by friendly name or type UUID, e.g. On or Brightness."),
                    "value": .object([
                        "description": .string("The target value: number, string, or boolean."),
                    ]),
                ],
                required: ["accessoryId", "characteristic", "value"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "create_service_group",
            description: "DEPRECATED — prefer create(kind: \"group\", homeId, name, serviceIds:). Create an empty service group (e.g. 'Desk Lamps'); add members with set_service_group_members. Groups contain services, not accessories. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                [
                    "homeId": stringProperty("The home to create the group in (from get_homes)."),
                    "name": stringProperty("The new group's name."),
                ],
                required: ["homeId", "name"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "rename_service_group",
            description: "DEPRECATED — prefer rename(entityId, newName). Rename a service group. Its members and devices are unaffected. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                [
                    "groupId": stringProperty("The group to rename (from get_service_groups)."),
                    "name": stringProperty("The group's new name."),
                ],
                required: ["groupId", "name"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "set_service_group_members",
            description: "DEPRECATED — prefer update(entityId, members:). Set a service group's complete membership — declarative: services absent from the list are removed. Service ids come from get_service_groups. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                [
                    "groupId": stringProperty("The group to update (from get_service_groups)."),
                    "serviceIds": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Every service the group should contain (from get_service_groups)."),
                    ]),
                ],
                required: ["groupId", "serviceIds"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "delete_service_group",
            description: "DEPRECATED — prefer delete(entityId). Delete a service group. Devices are unaffected — a group is a label over services. DESTRUCTIVE. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                ["groupId": stringProperty("The group to delete (from get_service_groups).")],
                required: ["groupId"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false, destructiveHint: true)
        ),
        Tool(
            name: "create_timer_trigger",
            description: "DEPRECATED — prefer create(kind: \"timer\", homeId, name, fireDate:). Create a timer automation (HomeKit HMTimerTrigger) with a fire date and optional recurrence. Created DISABLED — arming it requires a separate set_trigger_state approval, so an automation can never silently start running. Optionally runs an existing scene (sceneId from get_scenes). STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                [
                    "homeId": stringProperty("The home to create the trigger in (from get_homes)."),
                    "name": stringProperty("The new trigger's name."),
                    "fireDate": stringProperty("First fire time, ISO-8601, e.g. 2026-11-09T07:30:00Z."),
                    "recurrence": .object([
                        "type": .string("object"),
                        "description": .string("Optional repeat rule as date components, e.g. {\"weekday\": 1, \"hour\": 7, \"minute\": 30}. Omit for a one-shot trigger."),
                    ]),
                    "sceneId": stringProperty("Optional scene the trigger runs when it fires (from get_scenes)."),
                ],
                required: ["homeId", "name", "fireDate"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "create_event_trigger",
            description: "DEPRECATED — prefer create(kind: \"event\", homeId, name, events:). Create an event automation (HomeKit HMEventTrigger): characteristic events and/or presence events (atHome/away — presence is evaluated by HomeKit itself, no location access). Optionally restores the prior state after a duration (endEvents) and optionally runs once (executeOnce — HomeKit disables the trigger after its first fire). Created DISABLED — arming it requires a separate set_trigger_state approval. Optionally runs an existing scene (sceneId from get_scenes). STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                [
                    "homeId": stringProperty("The home to create the trigger in (from get_homes)."),
                    "name": stringProperty("The new trigger's name."),
                    "events": triggerEventsProperty("Every event that can activate the trigger."),
                    "endEvents": triggerEventsProperty(
                        "Optional events that end the effect and restore the prior state — e.g. end events on the same characteristics the trigger raised."
                    ),
                    "executeOnce": .object([
                        "type": .string("boolean"),
                        "description": .string("true runs the trigger once and HomeKit disables it afterwards."),
                    ]),
                    "sceneId": stringProperty("Optional scene the trigger runs when it fires (from get_scenes)."),
                ],
                required: ["homeId", "name", "events"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "update_event_trigger",
            description: "DEPRECATED — prefer update(entityId, events: …). Edit an event automation's contents: replace its events (declarative — the full list; presence events re-derive their predicate), and optionally its end events, days-of-week recurrences, or run-once behavior, and optionally re-point it at a different scene. Editing never changes the trigger's armed state — a disabled trigger stays disabled; arming stays a separate set_trigger_state approval. Timer triggers have no events; use set_trigger_state to move their schedule. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                [
                    "triggerId": stringProperty("The event trigger to edit (from get_triggers)."),
                    "events": triggerEventsProperty("The full replacement event list that can activate the trigger."),
                    "endEvents": triggerEventsProperty(
                        "Optional replacement end events; omit to leave them unchanged, pass [] to clear."
                    ),
                    "recurrences": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("object")]),
                        "description": .string(
                            "Optional days of the week when the trigger is evaluated, e.g. [{\"weekday\": 1}] (1 = Sunday). Omit to leave unchanged; pass [] to clear."
                        ),
                    ]),
                    "executeOnce": .object([
                        "type": .string("boolean"),
                        "description": .string("true runs the trigger once and HomeKit disables it afterwards; omit to leave unchanged."),
                    ]),
                    "sceneId": stringProperty(
                        "Optional scene the trigger runs when it fires (from get_scenes); re-points the trigger when passed, leaves the current scene untouched when omitted."
                    ),
                ],
                required: ["triggerId", "events"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "set_trigger_state",
            description: "Enable or disable an automation trigger — the arm/disarm step. Enabling is ALWAYS a separate proposal from creating the trigger: an agent can never silently flip an automation on. Also moves a timer trigger's fireDate/recurrence in the same approval. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                [
                    "triggerId": stringProperty("The trigger to update (from get_triggers)."),
                    "enabled": .object(["type": .string("boolean"), "description": .string("true to arm, false to disarm.")]),
                    "fireDate": stringProperty("Optional new first fire time, ISO-8601 (timer triggers only)."),
                    "recurrence": .object([
                        "type": .string("object"),
                        "description": .string("Optional new repeat rule as date components (timer triggers only)."),
                    ]),
                ],
                required: ["triggerId", "enabled"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "delete_trigger",
            description: "DEPRECATED — prefer delete(entityId). Delete an automation trigger — it stops firing immediately. DESTRUCTIVE. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                ["triggerId": stringProperty("The trigger to delete (from get_triggers).")],
                required: ["triggerId"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false, destructiveHint: true)
        ),
        Tool(
            name: "rename_accessory",
            description: "DEPRECATED — prefer rename(entityId, newName). Rename an accessory (e.g. a lamp) as it appears across HomeKit. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                [
                    "accessoryId": stringProperty("The accessory to rename (from get_rooms)."),
                    "name": stringProperty("The new accessory name."),
                ],
                required: ["accessoryId", "name"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "identify_accessory",
            description: "Identify an accessory: it flashes its light or beeps so a human can spot it. Harmless but physical. Rejected at staging when the accessory has no Identify capability. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                ["accessoryId": stringProperty("The accessory to identify (from get_rooms).")],
                required: ["accessoryId"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "assign_accessory_to_room",
            description: Self.assignAccessoryToRoomDescription + Self.stagingSuffix,
            inputSchema: objectSchema(
                [
                    "accessoryId": stringProperty("The accessory to move (from get_rooms)."),
                    "roomId": stringProperty("The destination room (from get_rooms)."),
                ],
                required: ["accessoryId", "roomId"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "unblock_accessory",
            description: "Unblock an accessory HomeKit has blocked (e.g. a paused or misbehaving bridge device) so it runs again. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                ["accessoryId": stringProperty("The accessory to unblock (from get_rooms).")],
                required: ["accessoryId"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false)
        ),
        Tool(
            name: "remove_accessory",
            description: "DEPRECATED — prefer delete(entityId). Remove an accessory from the home — its services leave their service groups, its scene actions die, and triggers watching its characteristics stop working. The review card lists every affected scene, group, and trigger. DESTRUCTIVE. STAGES A PROPOSAL — nothing is applied until a human approves it in Niles. Poll get_proposal afterwards.",
            inputSchema: objectSchema(
                ["accessoryId": stringProperty("The accessory to remove (from get_rooms).")],
                required: ["accessoryId"]
            ),
            annotations: Tool.Annotations(readOnlyHint: false, destructiveHint: true)
        ),
        Tool(
            name: "get_proposal",
            description: Self.getProposalDescription,
            inputSchema: objectSchema(
                ["proposalId": stringProperty("The proposal id returned by the write tool.")],
                required: ["proposalId"]
            ),
            annotations: Tool.Annotations(readOnlyHint: true)
        ),
    ]

    private static let sceneActionsProperty: Value = .object([
        "type": .string("array"),
        "items": .object([
            "type": .string("object"),
            "properties": .object([
                "accessoryId": .object([
                    "type": .string("string"),
                    "description": .string("The accessory whose service is written (from get_rooms)."),
                ]),
                "service": .object([
                    "type": .string("string"),
                    "description": .string("Optional service name or type; defaults to the accessory's primary service."),
                ]),
                "characteristic": .object([
                    "type": .string("string"),
                    "description": .string("The characteristic type to write, e.g. On or Brightness."),
                ]),
                "value": .object([
                    "description": .string("The target value: number, string, or boolean."),
                ]),
            ]),
            "required": .array([.string("accessoryId"), .string("characteristic"), .string("value")]),
        ]),
        "description": .string("Every characteristic write the scene should perform."),
    ])

    private static func triggerEventsProperty(_ description: String) -> Value {
        .object([
            "type": .string("array"),
            "items": .object([
                "type": .string("object"),
                "description": .string(
                    "Either a characteristic event {accessoryId, characteristic, value?} — value omitted means the event fires on any change — or a presence event {presence: \"atHome\" | \"away\"}."
                ),
                "properties": .object([
                    "accessoryId": .object([
                        "type": .string("string"),
                        "description": .string("The accessory whose characteristic is watched (from get_rooms)."),
                    ]),
                    "characteristic": .object([
                        "type": .string("string"),
                        "description": .string("The characteristic type to watch, e.g. On or MotionDetected."),
                    ]),
                    "value": .object([
                        "description": .string("Optional threshold value: number, string, or boolean."),
                    ]),
                    "presence": .object([
                        "type": .string("string"),
                        "description": .string("\"atHome\" or \"away\" — HomeKit evaluates presence itself; Niles never requests location access."),
                    ]),
                ]),
            ]),
            "description": .string(description),
        ])
    }

    private static func objectSchema(_ properties: [String: Value], required: [String]) -> Value {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
        ])
    }

    private static func stringProperty(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    // MARK: - Result rendering

    private static func result(_ proposal: Proposal, summary: String) throws -> CallTool.Result {
        // One encode for both channels: the text body and the structured
        // content mirror the same ISO-8601 JSON. The SDK's `Value(_:)`
        // conversion would otherwise emit Apple's reference-date doubles,
        // which agents cannot interpret unambiguously.
        let data = try encoder.encode(proposal)
        return try CallTool.Result(
            content: [.text(text: summary + "\n" + String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
            structuredContent: try JSONDecoder().decode(Value.self, from: data),
            isError: false
        )
    }

    private static func errorResult(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true
        )
    }

    private static func stagedSummary(for proposal: Proposal) -> String {
        var lines = [
            "STAGED — nothing has been applied. A human must approve this in Niles on the iPhone.",
            "Proposal \(proposal.id): \(proposal.title)",
        ]
        lines += cardLines(of: proposal)
        let expires = proposal.expiresAt.formatted(.iso8601)
        lines.append(
            "Expires at \(expires). Denial or expiry applies nothing. Poll get_proposal(proposalId: \"\(proposal.id)\") for the outcome."
        )
        return lines.joined(separator: "\n")
    }

    private static func statusSummary(for proposal: Proposal) -> String {
        var lines = ["\(proposal.state.rawValue.uppercased()): \(proposal.title)"]
        for line in cardLines(of: proposal) {
            lines.append(line)
        }
        for evidence in proposal.evidence {
            let mark = evidence.confirmed ? "✓" : "✗"
            lines.append("\(mark) \(evidence.claim) — \(evidence.observed)")
        }
        if let error = proposal.error {
            lines.append("Error: \(error)")
        }
        return lines.joined(separator: "\n")
    }

    private static func cardLines(of proposal: Proposal) -> [String] {
        proposal.card.map { line in
            switch line.kind {
            case .add: "+ \(line.text)"
            case .remove: "− \(line.text)"
            case .note: line.text
            case .plain: "  \(line.text)"
            }
        }
    }

    /// Agent-readable failure text. Validation rejections predate the
    /// proposal, so they always say nothing was staged.
    private static func message(for error: Error, tool: String) -> String {
        switch error {
        case let storeError as ProposalStoreError:
            switch storeError {
            case .unknownTool(let name):
                "Unknown tool \(name). Available write tools: \(Self.toolDefinitions.map(\.name).joined(separator: ", "))."
            case .invalidArguments(let detail):
                detail
            case .validationFailed(let messages):
                "Nothing was staged — validation failed:\n" + messages.map { "- \($0)" }.joined(separator: "\n")
            case .proposalNotFound(let id):
                "No proposal with id \(id)."
            case .proposalNotPending(let id, let state):
                "Proposal \(id) is \(state.rawValue), not pending."
            case .homeReadFailed(let detail):
                "Failed to read the home graph: \(detail)"
            case .notRevertable(let id):
                "Proposal \(id) cannot be undone — it has no paired revert (scene execution has no inverse, it never executed, or it was already undone)."
            case .undoConflict(let id, let divergences):
                "Proposal \(id) cannot be undone — the home has changed since it was applied, so the revert would not be safe. Nothing was changed. Divergences: "
                    + divergences.map { "\($0.claim): \($0.observed)" }.joined(separator: "; ")
            }
        case let plannerError as ProposalPlanner.PlannerError:
            "Nothing was staged: \(plannerError.message)"
        default:
            "Write tool \(tool) failed: \(String(describing: error))"
        }
    }

    /// Pretty-printed, key-sorted, ISO-8601 JSON — stable output for agents
    /// and for diffable test assertions.
    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
