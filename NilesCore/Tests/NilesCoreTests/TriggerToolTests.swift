import Foundation
import MCP
import Testing
@testable import NilesCore

/// The automation trigger tools end to end over the fake service: staging,
/// the locked rule that creation and enabling are always separate proposals,
/// and the deny path that leaves the trigger untouched. No test touches
/// `HMHomeManager`.
@Suite struct TriggerToolTests {
    private let t0 = Date(timeIntervalSince1970: 1_762_592_000)

    private func fixtureGraph() -> HomeGraph {
        let kitchen = HomeGraph.Room(
            id: "room-kitchen", name: "Kitchen",
            accessories: [HomeGraph.Accessory(id: "acc-light-a", name: "Light A")]
        )
        let home = HomeGraph.Home(
            id: "home-1",
            name: "Townhouse",
            rooms: [kitchen],
            scenes: [
                HomeGraph.Scene(
                    id: "scene-morning", name: "Good Morning", type: "AppleScene",
                    actions: [HomeGraph.SceneAction(
                        accessoryId: "acc-light-a", accessoryName: "Light A",
                        service: nil, characteristic: "On", characteristicName: nil,
                        valueDescription: "1"
                    )]
                )
            ]
        )
        return HomeGraph(homes: [home])
    }

    private func makeContext() -> (fake: FakeHomeKitService, store: ProposalStore, registry: WriteToolRegistry) {
        let fake = FakeHomeKitService(graph: fixtureGraph())
        let store = ProposalStore(homeKit: fake, now: { self.t0 })
        let registry = WriteToolRegistry(store: store)
        return (fake, store, registry)
    }

    /// Decodes a successful write-tool result's structured content into the
    /// proposal envelope the agent polls.
    private func proposal(from result: CallTool.Result, sourceLocation: SourceLocation = #_sourceLocation) throws -> Proposal {
        #expect(result.isError != true, sourceLocation: sourceLocation)
        let value = try #require(result.structuredContent, sourceLocation: sourceLocation)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Proposal.self, from: JSONEncoder().encode(value))
    }

    private func errorText(of result: CallTool.Result) -> String? {
        guard result.isError == true else { return nil }
        for case let .text(text, _, _) in result.content {
            return text
        }
        return nil
    }

    private func findTrigger(_ graph: HomeGraph) -> HomeGraph.Trigger? {
        graph.homes.first?.triggers.first
    }

    // MARK: - Timer trigger staging

    @Test func timerTriggerStagesDisabledAndExecutesDisabled() async throws {
        let (fake, store, registry) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "create_timer_trigger",
            arguments: [
                "homeId": .string("home-1"),
                "name": .string("Wake Up"),
                "fireDate": .string("2026-11-09T07:30:00Z"),
                "recurrence": .object(["hour": .int(7), "minute": .int(30)]),
                "sceneId": .string("scene-morning"),
            ]
        ))

        // Staged, not executed: the home is untouched at staging time.
        #expect(staged.state == .staged)
        #expect(staged.tool == "create_timer_trigger")
        #expect(staged.card.contains { $0.text.contains("DISABLED") })
        #expect(staged.card.contains { $0.kind == .note && $0.text.contains("separate") })
        let graphAtStaging = await fake.graph
        #expect(findTrigger(graphAtStaging) == nil)

        let approved = try await store.approve(id: staged.id)
        #expect(approved.state == .executed)
        #expect(approved.error == nil)

        let graph = await fake.graph
        let created = try #require(findTrigger(graph))
        // The locked rule holds after execution: creation never arms.
        #expect(created.isEnabled == false)
        #expect(created.name == "Wake Up")
        if case .timer(let createdFireDate, let recurrence) = created.detail {
            #expect(createdFireDate == Self.isoDate("2026-11-09T07:30:00Z"))
            #expect(recurrence == ["hour": 7, "minute": 30])
        } else {
            Issue.record("Expected a timer detail, got \(created.detail)")
        }
        #expect(approved.evidence.first?.confirmed == true)
        #expect(approved.evidence.first?.observed.contains("disabled") == true)
    }

    // MARK: - Event trigger staging

    @Test func eventTriggerStagesCharacteristicAndPresenceEvents() async throws {
        let (fake, store, registry) = makeContext()

        let staged = try proposal(from: await registry.call(
            name: "create_event_trigger",
            arguments: [
                "homeId": .string("home-1"),
                "name": "Arrive Home",
                "events": .array([
                    .object([
                        "accessoryId": .string("acc-light-a"),
                        "characteristic": .string("MotionDetected"),
                        "value": .bool(true),
                    ]),
                    .object(["presence": .string("atHome")]),
                ]),
                "sceneId": .string("scene-morning"),
            ]
        ))

        #expect(staged.state == .staged)
        // Presence events are rendered on the card, not sent to a location API.
        #expect(staged.card.contains { $0.text.contains("someone arrives home") })
        #expect(staged.card.contains { $0.text.contains("Light A MotionDetected reaches 1") })

        let approved = try await store.approve(id: staged.id)
        #expect(approved.state == .executed)

        let graph = await fake.graph
        let created = try #require(findTrigger(graph))
        #expect(created.isEnabled == false)
        guard case .event(let detail) = created.detail else {
            Issue.record("Expected an event detail, got \(created.detail)")
            return
        }
        #expect(detail.events == [
            HomeGraph.EventRef(type: "characteristic", characteristicType: "MotionDetected", valueDescription: "1", accessoryId: "acc-light-a"),
            HomeGraph.EventRef(type: "presence", characteristicType: nil, valueDescription: "atHome"),
        ])
        // Presence events imply the presence predicate; the structured read
        // carries it, and the trigger is fully readable.
        #expect(detail.predicate?.contains("presence") == true)
        #expect(detail.presence?.atHome == true)
        #expect(detail.readable == true)
        #expect(approved.evidence.first?.confirmed == true)
    }

    @Test func unknownAccessoryInEventIsRejectedBeforeStaging() async throws {
        let (_, store, registry) = makeContext()

        let result = await registry.call(
            name: "create_event_trigger",
            arguments: [
                "homeId": .string("home-1"),
                "name": "Ghost Trigger",
                "events": .array([
                    .object(["accessoryId": .string("acc-nope"), "characteristic": .string("On")]),
                ]),
            ]
        )
        #expect(result.isError == true)
        #expect(errorText(of: result)?.contains("Nothing was staged") == true)
        #expect(errorText(of: result)?.contains("Event 1") == true)
        #expect(await store.allProposals().isEmpty)
    }

    @Test func sceneReferenceMustExistInTheSameHome() async throws {
        let (_, _, registry) = makeContext()

        let result = await registry.call(
            name: "create_timer_trigger",
            arguments: [
                "homeId": .string("home-1"),
                "name": .string("Wake Up"),
                "fireDate": .string("2026-11-09T07:30:00Z"),
                "sceneId": .string("scene-nope"),
            ]
        )
        #expect(result.isError == true)
        #expect(errorText(of: result)?.contains("Nothing was staged") == true)
    }

    // MARK: - The locked rule: create and enable are separate proposals

    @Test func createThenEnableProducesTwoDistinctProposals() async throws {
        let (fake, store, registry) = makeContext()

        let created = try proposal(from: await registry.call(
            name: "create_timer_trigger",
            arguments: [
                "homeId": .string("home-1"),
                "name": .string("Wake Up"),
                "fireDate": .string("2026-11-09T07:30:00Z"),
                "sceneId": .string("scene-morning"),
            ]
        ))
        #expect(created.tool == "create_timer_trigger")
        #expect(created.state == .staged)

        let createdApproved = try await store.approve(id: created.id)
        #expect(createdApproved.state == .executed)

        // Arming is a SECOND proposal — never folded into creation.
        let enable = try proposal(from: await registry.call(
            name: "set_trigger_state",
            arguments: ["triggerId": .string("trigger-1"), "enabled": .bool(true)]
        ))
        #expect(enable.tool == "set_trigger_state")
        #expect(enable.id != created.id)
        #expect(enable.state == .staged)
        // Two cards exist in the queue; the enable card says what arming does.
        #expect(await store.allProposals().count == 2)
        #expect(enable.card.contains { $0.kind == .note && $0.text.contains("Arming") })

        let graphBeforeArm = await fake.graph
        #expect(findTrigger(graphBeforeArm)?.isEnabled == false)

        let enabled = try await store.approve(id: enable.id)
        #expect(enabled.state == .executed)
        #expect(enabled.evidence.first?.confirmed == true)

        let graph = await fake.graph
        #expect(findTrigger(graph)?.isEnabled == true)
    }

    @Test func deniedEnableLeavesTriggerUntouched() async throws {
        let (fake, store, registry) = makeContext()

        let created = try proposal(from: await registry.call(
            name: "create_timer_trigger",
            arguments: [
                "homeId": .string("home-1"),
                "name": .string("Wake Up"),
                "fireDate": .string("2026-11-09T07:30:00Z"),
                "sceneId": .string("scene-morning"),
            ]
        ))
        _ = try await store.approve(id: created.id)

        let enable = try proposal(from: await registry.call(
            name: "set_trigger_state",
            arguments: ["triggerId": .string("trigger-1"), "enabled": .bool(true)]
        ))
        let denied = try await store.deny(id: enable.id)

        // Denial is terminal, applies nothing, and the trigger stays disabled.
        #expect(denied.state == .denied)
        #expect(denied.state.leftHomeUntouched)
        #expect(denied.evidence.isEmpty)
        let graph = await fake.graph
        #expect(findTrigger(graph)?.isEnabled == false)
        #expect(findTrigger(graph)?.name == "Wake Up")
    }

    @Test func schedulingAnAlreadyEnabledTriggerIsNoChange() async throws {
        let (_, store, registry) = makeContext()

        let created = try proposal(from: await registry.call(
            name: "create_timer_trigger",
            arguments: [
                "homeId": .string("home-1"),
                "name": .string("Wake Up"),
                "fireDate": .string("2026-11-09T07:30:00Z"),
                "sceneId": .string("scene-morning"),
            ]
        ))
        _ = try await store.approve(id: created.id)

        let enable = try proposal(from: await registry.call(
            name: "set_trigger_state",
            arguments: ["triggerId": .string("trigger-1"), "enabled": .bool(true)]
        ))
        _ = try await store.approve(id: enable.id)

        // An identical enable is a no-op: the planner rejects it in-band
        // rather than staging a second, redundant arm proposal.
        let again = await registry.call(
            name: "set_trigger_state",
            arguments: ["triggerId": .string("trigger-1"), "enabled": .bool(true)]
        )
        #expect(again.isError == true)
        #expect(errorText(of: again)?.contains("already enabled") == true)
        #expect(await store.allProposals().count == 2)
    }

    // MARK: - Timer schedule update rides the state change

    @Test func timerFireDateMoveRidesTheStateApproval() async throws {
        let (fake, store, registry) = makeContext()

        _ = try proposal(from: await registry.call(
            name: "create_timer_trigger",
            arguments: [
                "homeId": .string("home-1"),
                "name": .string("Wake Up"),
                "fireDate": .string("2026-11-09T07:30:00Z"),
                "sceneId": .string("scene-morning"),
            ]
        ))
        let created = await store.allProposals().first!
        _ = try await store.approve(id: created.id)

        let update = try proposal(from: await registry.call(
            name: "set_trigger_state",
            arguments: [
                "triggerId": .string("trigger-1"),
                "enabled": .bool(true),
                "fireDate": .string("2026-11-10T08:00:00Z"),
            ]
        ))
        let updated = try await store.approve(id: update.id)
        #expect(updated.state == .executed)

        let graph = await fake.graph
        let trigger = try #require(findTrigger(graph))
        #expect(trigger.isEnabled == true)
        if case .timer(let fireDate, _) = trigger.detail {
            #expect(fireDate == Self.isoDate("2026-11-10T08:00:00Z"))
        } else {
            Issue.record("Expected a timer detail, got \(trigger.detail)")
        }
    }

    // MARK: - Delete

    @Test func deleteTriggerStagesAndExecutesWithEvidence() async throws {
        let (fake, store, registry) = makeContext()

        let created = try proposal(from: await registry.call(
            name: "create_timer_trigger",
            arguments: [
                "homeId": .string("home-1"),
                "name": .string("Wake Up"),
                "fireDate": .string("2026-11-09T07:30:00Z"),
            ]
        ))
        _ = try await store.approve(id: created.id)

        let delete = try proposal(from: await registry.call(
            name: "delete_trigger",
            arguments: ["triggerId": .string("trigger-1")]
        ))
        #expect(delete.isDestructive)
        #expect(delete.card.contains { $0.kind == .plain && $0.text.contains("stops firing") })

        let deleted = try await store.approve(id: delete.id)
        #expect(deleted.state == .executed)
        let graph = await fake.graph
        #expect(findTrigger(graph) == nil)
        #expect(deleted.evidence.first?.confirmed == true)
    }

    @Test func deniedDeleteLeavesTriggerUntouched() async throws {
        let (fake, store, registry) = makeContext()

        let created = try proposal(from: await registry.call(
            name: "create_timer_trigger",
            arguments: [
                "homeId": .string("home-1"),
                "name": .string("Wake Up"),
                "fireDate": .string("2026-11-09T07:30:00Z"),
            ]
        ))
        _ = try await store.approve(id: created.id)

        let delete = try proposal(from: await registry.call(
            name: "delete_trigger",
            arguments: ["triggerId": .string("trigger-1")]
        ))
        _ = try await store.deny(id: delete.id)

        let graph = await fake.graph
        #expect(findTrigger(graph)?.name == "Wake Up")
        #expect(findTrigger(graph)?.isEnabled == false)
    }

    // MARK: - Event trigger editing

    /// The edit path end to end over the fake: a declarative event swap
    /// stages a diff card, executes, and read-back confirms — while the
    /// trigger's armed state is untouched (the create/arm firewall).
    @Test func editingAnEventTriggerStagesADiffAndPreservesItsArmedState() async throws {
        let (fake, store, registry) = makeContext()

        let created = try proposal(from: await registry.call(
            name: "create_event_trigger",
            arguments: [
                "homeId": .string("home-1"),
                "name": .string("Lights On"),
                "events": .array([
                    .object([
                        "accessoryId": .string("acc-light-a"),
                        "characteristic": .string("On"),
                        "value": .bool(true),
                    ]),
                ]),
                "sceneId": .string("scene-morning"),
            ]
        ))
        _ = try await store.approve(id: created.id)

        // The edit: swap the characteristic event for a presence event.
        let edit = try proposal(from: await registry.call(
            name: "update_event_trigger",
            arguments: [
                "triggerId": .string("trigger-1"),
                "events": .array([.object(["presence": .string("atHome")])]),
            ]
        ))
        #expect(edit.tool == "update_event_trigger")
        // The card diffs the declarative list and states the firewall.
        #expect(edit.card.contains { $0.kind == .remove && $0.text.contains("remove event") })
        #expect(edit.card.contains { $0.kind == .add && $0.text.contains("someone arrives home") })
        #expect(edit.card.contains { $0.kind == .note && $0.text.contains("stays disabled") })

        let approved = try await store.approve(id: edit.id)
        #expect(approved.state == .executed)
        #expect(approved.evidence.first?.confirmed == true)

        let graph = await fake.graph
        let edited = try #require(findTrigger(graph))
        // The create/arm firewall: editing never silently enables.
        #expect(edited.isEnabled == false)
        guard case .event(let detail) = edited.detail else {
            Issue.record("Expected an event detail, got \(edited.detail)")
            return
        }
        #expect(detail.events == [HomeGraph.EventRef(type: "presence", characteristicType: nil, valueDescription: "atHome")])
        #expect(detail.predicate?.contains("presence") == true)
    }

    @Test func deniedEventTriggerUpdateLeavesTriggerUntouched() async throws {
        let (fake, store, registry) = makeContext()

        let created = try proposal(from: await registry.call(
            name: "create_event_trigger",
            arguments: [
                "homeId": .string("home-1"),
                "name": .string("Lights On"),
                "events": .array([
                    .object([
                        "accessoryId": .string("acc-light-a"),
                        "characteristic": .string("On"),
                        "value": .bool(true),
                    ]),
                ]),
                "sceneId": .string("scene-morning"),
            ]
        ))
        _ = try await store.approve(id: created.id)

        let edit = try proposal(from: await registry.call(
            name: "update_event_trigger",
            arguments: [
                "triggerId": .string("trigger-1"),
                "events": .array([.object(["presence": .string("away")])]),
            ]
        ))
        let denied = try await store.deny(id: edit.id)

        // Denial is terminal, applies nothing, and the trigger keeps its
        // original events and disabled state.
        #expect(denied.state == .denied)
        #expect(denied.state.leftHomeUntouched)
        #expect(denied.evidence.isEmpty)
        let graph = await fake.graph
        let untouched = try #require(findTrigger(graph))
        #expect(untouched.isEnabled == false)
        guard case .event(let detail) = untouched.detail else {
            Issue.record("Expected an event detail, got \(untouched.detail)")
            return
        }
        #expect(detail.events.first?.characteristicType == "On")
    }

    @Test func editingAnEventTriggerWithTheSameEventsIsNoChange() async throws {
        let (_, store, registry) = makeContext()

        let created = try proposal(from: await registry.call(
            name: "create_event_trigger",
            arguments: [
                "homeId": .string("home-1"),
                "name": .string("Lights On"),
                "events": .array([
                    .object([
                        "accessoryId": .string("acc-light-a"),
                        "characteristic": .string("On"),
                        "value": .bool(true),
                    ]),
                ]),
            ]
        ))
        _ = try await store.approve(id: created.id)

        // An identical event list is a no-op: the planner rejects it in-band
        // rather than staging a redundant edit (canonical matching — the
        // same event however the value is rendered).
        let again = await registry.call(
            name: "update_event_trigger",
            arguments: [
                "triggerId": .string("trigger-1"),
                "events": .array([
                    .object([
                        "accessoryId": .string("acc-light-a"),
                        "characteristic": .string("On"),
                        "value": .bool(true),
                    ]),
                ]),
            ]
        )
        #expect(again.isError == true)
        #expect(errorText(of: again)?.contains("already watches exactly these events") == true)
        #expect(await store.allProposals().count == 1)
    }

    @Test func createEventTriggerWithEndEventsAndExecuteOnceStagesAndExecutes() async throws {
        let (fake, store, registry) = makeContext()

        let created = try proposal(from: await registry.call(
            name: "create_event_trigger",
            arguments: [
                "homeId": .string("home-1"),
                "name": .string("Pulse"),
                "events": .array([
                    .object([
                        "accessoryId": .string("acc-light-a"),
                        "characteristic": .string("On"),
                        "value": .bool(true),
                    ]),
                ]),
                "endEvents": .array([
                    .object([
                        "accessoryId": .string("acc-light-a"),
                        "characteristic": .string("On"),
                        "value": .bool(false),
                    ]),
                ]),
                "executeOnce": .bool(true),
            ]
        ))
        // The card renders both the end events and the run-once behavior.
        #expect(created.card.contains { $0.text.contains("Ends with") })
        #expect(created.card.contains { $0.text.contains("Runs once") })

        let approved = try await store.approve(id: created.id)
        #expect(approved.state == .executed)
        #expect(approved.evidence.first?.confirmed == true)
        // Born disabled, and everything the write path accepts reads back:
        // events, end events, and the run-once behavior are all observable
        // on the graph detail.
        let graph = await fake.graph
        let trigger = try #require(findTrigger(graph))
        #expect(trigger.isEnabled == false)
        guard case .event(let detail) = trigger.detail else {
            Issue.record("Expected an event detail, got \(trigger.detail)")
            return
        }
        #expect(detail.events.count == 1 && detail.events.first?.characteristicType == "On")
        #expect(detail.endEvents == [HomeGraph.EventRef(type: "characteristic", characteristicType: "On", valueDescription: "0", accessoryId: "acc-light-a")])
        #expect(detail.executeOnce == true)
        #expect(detail.readable == true)
    }

    // MARK: - Argument errors, reported in-band

    @Test func malformedArgumentsAreReportedInBand() async throws {
        let (_, _, registry) = makeContext()

        let badDate = await registry.call(
            name: "create_timer_trigger",
            arguments: [
                "homeId": .string("home-1"),
                "name": .string("Wake Up"),
                "fireDate": .string("tomorrow at 7"),
            ]
        )
        #expect(badDate.isError == true)
        #expect(errorText(of: badDate)?.contains("ISO-8601") == true)

        let badRecurrence = await registry.call(
            name: "create_timer_trigger",
            arguments: [
                "homeId": .string("home-1"),
                "name": .string("Wake Up"),
                "fireDate": .string("2026-11-09T07:30:00Z"),
                "recurrence": .object(["weekdays": .int(1)]),
            ]
        )
        #expect(badRecurrence.isError == true)
        #expect(errorText(of: badRecurrence)?.contains("unknown component") == true)

        let badPresence = await registry.call(
            name: "create_event_trigger",
            arguments: [
                "homeId": .string("home-1"),
                "name": .string("Arrive Home"),
                "events": .array([.object(["presence": .string("nearby")])]),
            ]
        )
        #expect(badPresence.isError == true)
        #expect(errorText(of: badPresence)?.contains("atHome") == true)

        let missingEvents = await registry.call(
            name: "create_event_trigger",
            arguments: ["homeId": .string("home-1"), "name": .string("Arrive Home")]
        )
        #expect(missingEvents.isError == true)
        #expect(errorText(of: missingEvents)?.contains("events") == true)
    }

    /// The shared ISO-8601 shape the arguments and assertions both use.
    private static func isoDate(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)!
    }
}
