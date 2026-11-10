import Foundation
import MCP
import Testing
@testable import NilesCore

/// The skill walkthrough (Blueprint art_34OYtrUm, "Skill walkthrough"): a
/// scripted run against the fake server in which every step follows the
/// client skill's guidance — pair → lean read → ambiguous search →
/// declarative scene edit stating the full action list → unreadable-trigger
/// edit surfaced → separate arming proposal. A failure anywhere is a step
/// where the skill's guidance would have the client guess an id, silently
/// delete members, or edit an unreadable trigger.
@Suite struct SkillWalkthroughTests {
    private let t0 = Date(timeIntervalSince1970: 1_762_592_000)

    // MARK: - Fixtures

    /// A token store that always succeeds — the walkthrough's pairing step
    /// exercises the exchange, not Keychain failure modes (see PairingTests).
    private struct InMemoryTokenStore: TokenStoring {
        let issued = PairedAgent(
            id: UUID(), name: nil, token: "walkthrough-bearer-token",
            pairedAt: Date(timeIntervalSince1970: 1_762_592_000)
        )
        func loadOrCreate() throws -> String { issued.token }
        func listAgents() throws -> [PairedAgent] { [issued] }
        func issueToken(name: String?) throws -> PairedAgent {
            PairedAgent(
                id: UUID(), name: name, token: issued.token,
                pairedAt: Date(timeIntervalSince1970: 1_762_592_000)
            )
        }
        func revoke(id: UUID) throws {}
    }

    /// The walkthrough home: two ambiguous "Lamp" names plus a distinct one
    /// (for search ambiguity), a scene with one existing action (for the
    /// declarative full-list edit), a Niles-written trigger (readable), and
    /// a foreign-predicate trigger (unreadable).
    private func walkthroughGraph() -> HomeGraph {
        let livingRoom = HomeGraph.Room(
            id: "room-living", name: "Living Room",
            accessories: [
                AgentFixtures.dimmableLight(id: "acc-lr-1", name: "Living Room Lamp 1"),
                AgentFixtures.dimmableLight(id: "acc-lr-2", name: "Living Room Lamp 2"),
            ]
        )
        let kitchen = HomeGraph.Room(
            id: "room-kitchen", name: "Kitchen",
            accessories: [AgentFixtures.dimmableLight(id: "acc-kitchen-1", name: "Kitchen Lamp")]
        )
        let morningScene = HomeGraph.Scene(
            id: "scene-morning", name: "Good Morning", type: "AppleScene",
            actions: [HomeGraph.SceneAction(
                accessoryId: "acc-kitchen-1", accessoryName: "Kitchen Lamp",
                service: nil, characteristic: "Brightness", characteristicName: "Brightness",
                valueDescription: "80"
            )]
        )
        let motion = HomeGraph.Trigger(
            id: "trigger-motion", name: "Motion lights", isEnabled: false,
            detail: .event(HomeGraph.Trigger.Detail.EventDetail(
                events: [HomeGraph.EventRef(
                    type: "characteristic", characteristicType: "Brightness",
                    valueDescription: "0", accessoryId: "acc-lr-1"
                )],
                predicate: nil, readable: true
            ))
        )
        // A trigger with parts the structured read cannot represent — a
        // predicate Niles did not write. `readable == false` is the flag the
        // skill teaches clients to check before any declarative edit.
        let alarm = HomeGraph.Trigger(
            id: "trigger-alarm", name: "Alarm strobe", isEnabled: false,
            detail: .event(HomeGraph.Trigger.Detail.EventDetail(
                events: [HomeGraph.EventRef(
                    type: "characteristic", characteristicType: "Brightness",
                    valueDescription: "100", accessoryId: "acc-lr-1"
                )],
                predicate: "accessoryid == 'acc-lr-1' AND value > 50", readable: false
            ))
        )
        let home = HomeGraph.Home(
            id: "home-1", name: "Main House", rooms: [livingRoom, kitchen],
            scenes: [morningScene], triggers: [motion, alarm]
        )
        return HomeGraph(homes: [home])
    }

    private func makeContext() -> (
        fake: FakeHomeKitService, store: ProposalStore, reads: ReadToolRegistry, writes: WriteToolRegistry
    ) {
        let fake = FakeHomeKitService(graph: walkthroughGraph())
        let store = ProposalStore(homeKit: fake, now: { self.t0 })
        return (fake, store, ReadToolRegistry(service: fake), WriteToolRegistry(store: store))
    }

    // MARK: - Result helpers

    private func text(of result: CallTool.Result, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        #expect(result.isError != true, sourceLocation: sourceLocation)
        for case let .text(text, _, _) in result.content {
            return text
        }
        return ""
    }

    private func jsonObject(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> [String: Any] {
        try #require(
            JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            sourceLocation: sourceLocation
        )
    }

    private func proposal(from result: CallTool.Result, sourceLocation: SourceLocation = #_sourceLocation) throws -> Proposal {
        #expect(result.isError != true, sourceLocation: sourceLocation)
        let value = try #require(result.structuredContent, sourceLocation: sourceLocation)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Proposal.self, from: JSONEncoder().encode(value))
    }

    // MARK: - The walkthrough

    @Test func skillWalkthrough() async throws {
        // Step 1 — pair. The human reads the six-digit code from Settings;
        // the client trades it once for a bearer token (skill §2).
        let codes = PairingCodeManager(now: { self.t0 })
        let code = try await codes.mintCode()
        let pairing = PairingService(codes: codes, tokens: InMemoryTokenStore())
        let exchangeBody = try JSONSerialization.data(withJSONObject: [
            "code": code.code, "name": "Skill walkthrough agent",
        ])
        let exchange = await pairing.handle(MCP.HTTPRequest(
            method: "POST", headers: [:], body: exchangeBody, path: PairingService.defaultPath
        ))
        let exchangeResponse = try #require(exchange)
        #expect(exchangeResponse.statusCode == 200)
        let tokenBody = try jsonObject(String(decoding: exchangeResponse.body, as: UTF8.self))
        let token = try #require(tokenBody["access_token"] as? String)
        #expect(!token.isEmpty)

        let (fake, store, reads, writes) = makeContext()

        // Step 2 — lean read. The skill says start from `get_details` with
        // no arguments: a summary without characteristic payloads, not a
        // whole-home dump.
        let leanRead = await reads.call(name: "get_details")
        let leanText = try text(of: leanRead)
        let lean = try jsonObject(leanText)
        let leanHomes = try #require(lean["homes"] as? [[String: Any]])
        #expect(leanHomes.count == 1)
        #expect(leanHomes.first?["counts"] != nil)
        // Lean: rooms carry accessory NAMES, never characteristic payloads.
        #expect(leanText.contains("Living Room Lamp 1"))
        #expect(!leanText.contains("characteristics"))

        // Step 3 — ambiguous search. "Lamp" matches three accessories; the
        // skill says ask the human which one they meant, never pick an id.
        let search = await reads.call(name: "search", arguments: ["query": .string("lamp")])
        let searchObject = try jsonObject(try text(of: search))
        let hits = try #require(searchObject["results"] as? [[String: Any]])
        #expect(hits.count == 3)
        #expect(hits.allSatisfy { ($0["id"] as? String)?.isEmpty == false })
        #expect(hits.allSatisfy { $0["kind"] as? String == "accessory" })
        #expect(hits.allSatisfy { $0["context"] != nil })
        // The human resolves the ambiguity: the Kitchen Lamp is the one.
        let kitchenLamp = try #require(hits.first { $0["name"] as? String == "Kitchen Lamp" })
        #expect(kitchenLamp["id"] as? String == "acc-kitchen-1")

        // Step 4 — declarative scene edit stating the FULL action list.
        // Read the scene first…
        let sceneRead = await reads.call(
            name: "get_details", arguments: ["kind": .string("scene"), "id": .string("scene-morning")]
        )
        let sceneObject = try jsonObject(try text(of: sceneRead))
        let existingActions = try #require(sceneObject["actions"] as? [[String: Any]])
        #expect(existingActions.count == 1)

        // …then "add Living Room Lamp 1 at 40 to Good Morning": the skill's
        // declarative-means-destructive rule says update REPLACES the
        // complete list, so the walkthrough restates the existing action
        // alongside the new one — the delta-only call would have deleted it.
        let fullActionList: MCP.Value = .array([
            .object([
                "accessoryId": .string("acc-kitchen-1"),
                "characteristic": .string("Brightness"),
                "value": .int(80),
            ]),
            .object([
                "accessoryId": .string("acc-lr-1"),
                "characteristic": .string("Brightness"),
                "value": .int(40),
            ]),
        ])
        let sceneEdit = await writes.call(name: "update", arguments: [
            "entityId": .string("scene-morning"), "actions": fullActionList,
        ])
        let sceneProposal = try proposal(from: sceneEdit)
        #expect(sceneProposal.state == .staged)
        let approvedScene = try await store.approve(id: sceneProposal.id)
        #expect(approvedScene.state == .executed)
        let graphAfterSceneEdit = await fake.graph
        let scene = try #require(graphAfterSceneEdit.homes.first?.scenes.first { $0.id == "scene-morning" })
        // Both actions applied — the full list was stated, nothing dangled.
        #expect(scene.actions.count == 2)
        #expect(scene.actions.contains { $0.accessoryId == "acc-kitchen-1" && $0.valueDescription == "80" })
        #expect(scene.actions.contains { $0.accessoryId == "acc-lr-1" && $0.valueDescription == "40" })

        // Step 5 — read before declarative edits on triggers. The unreadable
        // trigger surfaces `readable: false` (plus the raw predicate), the
        // walkthrough stages NOTHING against it — the skill says surface
        // "unreadable parts will be discarded" to the human instead.
        let alarmRead = await reads.call(
            name: "get_details", arguments: ["kind": .string("trigger"), "id": .string("trigger-alarm")]
        )
        let alarmObject = try jsonObject(try text(of: alarmRead))
        let alarmDetail = try #require(alarmObject["detail"] as? [String: Any])
        let alarmEvent = try #require(alarmDetail["event"] as? [String: Any])
        #expect(alarmEvent["readable"] as? Bool == false)
        #expect((alarmEvent["predicate"] as? String)?.isEmpty == false)
        let proposalsBeforeUnreadableEdit = await store.allProposals().count

        // The contrast: the readable trigger (Niles wrote it) edits fine.
        let readableRead = await reads.call(
            name: "get_details", arguments: ["kind": .string("trigger"), "id": .string("trigger-motion")]
        )
        let readableObject = try jsonObject(try text(of: readableRead))
        let readableDetail = try #require(readableObject["detail"] as? [String: Any])
        let readableEvent = try #require(readableDetail["event"] as? [String: Any])
        #expect(readableEvent["readable"] as? Bool == true)
        let readableEdit = await writes.call(name: "update", arguments: [
            "entityId": .string("trigger-motion"),
            "events": .array([.object([
                "accessoryId": .string("acc-lr-2"), "characteristic": .string("On"),
            ])]),
        ])
        let readableProposal = try proposal(from: readableEdit)
        #expect(readableProposal.state == .staged)
        // Only the readable edit staged — the unreadable trigger staged nothing.
        let proposalsAfterReadableEdit = await store.allProposals().count
        #expect(proposalsAfterReadableEdit == proposalsBeforeUnreadableEdit + 1)

        // Step 6 — automation arming is ALWAYS its own proposal. Create the
        // automation; it stages…
        let created = await writes.call(name: "create", arguments: [
            "kind": .string("event"), "homeId": .string("home-1"), "name": .string("Evening Wind Down"),
            "events": .array([.object([
                "accessoryId": .string("acc-kitchen-1"), "characteristic": .string("On"),
                "value": .bool(false),
            ])]),
            "sceneId": .string("scene-morning"),
        ])
        let createProposal = try proposal(from: created)
        #expect(createProposal.state == .staged)
        let approvedCreate = try await store.approve(id: createProposal.id)
        #expect(approvedCreate.state == .executed)

        // …executed DISABLED — creation never arms…
        let graphAfterCreate = await fake.graph
        let createdTrigger = try #require(
            graphAfterCreate.homes.first?.triggers.first { $0.name == "Evening Wind Down" }
        )
        #expect(createdTrigger.isEnabled == false)

        // …and arming is a second, separate proposal with its own id.
        let arming = await writes.call(name: "set_trigger_state", arguments: [
            "triggerId": .string(createdTrigger.id), "enabled": .bool(true),
        ])
        let armingProposal = try proposal(from: arming)
        #expect(armingProposal.state == .staged)
        #expect(armingProposal.id != createProposal.id)
    }
}
