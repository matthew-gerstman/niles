import Foundation
import Testing
@testable import NilesCore

/// Service-group membership read depth (Blueprint art_H3kJluSG, PR A): the
/// failure behind the blind-grouping batch was a read model that presented
/// empty group membership as fact — every group read `services: []`, so a
/// caller could not tell "genuinely empty" from "HomeKit did not hydrate
/// membership in this process", and cross-group conflict detection at
/// staging was impossible.
///
/// Pins both group projection paths:
/// - the deep read (`get_details(kind: "group")`) lists member services
///   with name, service type, and owning accessory, and an empty-read
///   group carries the explicit membership note instead of bare emptiness;
/// - the lean summary's group lines carry the same note.
///
/// Follows the PR #15 validation-test pattern: pure fixtures over
/// `FakeHomeKitService` — no HMHomeManager.
@Suite struct ServiceGroupMembershipReadTests {

    // MARK: - Fixtures

    /// HAP window-covering service type — the kind the blind-grouping
    /// batch tried to group when the bare-empty reads hid the failure.
    private static let windowCoveringType = "0000006B-0000-1000-8000-0026BB765291"

    private func fixtureGraph() -> HomeGraph {
        let blindService = HomeGraph.AccessoryService(
            id: "svc-blind-right", name: "Right Blind",
            serviceType: Self.windowCoveringType,
            characteristics: []
        )
        let blindAccessory = HomeGraph.Accessory(
            id: "acc-blinds", name: "Living Room Blinds", reachable: true,
            bridged: false, category: "com.apple.hap.windowcovering", services: [blindService]
        )
        let living = HomeGraph.Room(id: "room-living", name: "Living Room", accessories: [blindAccessory])
        let home = HomeGraph.Home(id: "home-1", name: "Syracuse", rooms: [living])
        var graph = HomeGraph(homes: [home])
        graph.homes[0].serviceGroups = [
            HomeGraph.ServiceGroup(
                id: "group-blinds", name: "Living Room Blinds",
                services: [
                    HomeGraph.ServiceRef(
                        id: "svc-blind-right", name: "Right Blind",
                        serviceType: Self.windowCoveringType,
                        accessoryId: "acc-blinds", accessoryName: "Living Room Blinds"
                    ),
                ]
            ),
            // The failure shape: HomeKit reports no members — genuinely
            // empty or unhydrated; the read cannot tell and must say so.
            HomeGraph.ServiceGroup(id: "group-debris", name: "Living Room Blinds Debris"),
        ]
        return graph
    }

    private func deepRead(_ registry: ReadToolRegistry, id: String) async throws
        -> ReadToolRegistry.FullObject<ReadToolRegistry.ServiceGroupSummary> {
        let result = await registry.call(
            name: "get_details",
            arguments: ["kind": .string("group"), "id": .string(id)]
        )
        #expect(!result.isError)
        return try Self.decode(Self.textContent(result))
    }

    private static func textContent(_ result: CallTool.Result) -> String {
        guard case let .text(text, _, _) = result.content.first else {
            Issue.record("Expected a text content block, got \(result.content)")
            return ""
        }
        return text
    }

    private static func decode<T: Decodable>(_ text: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(text.utf8))
    }

    private static let expectedNote = "membership unavailable — HomeKit reported no members"

    // MARK: - Deep read (get_details kind: "group")

    /// A populated group's deep read lists member services with name,
    /// service type, and owning accessory — the detail the blind-grouping
    /// diagnosis needs to name what HomeKit refused.
    @Test func deepReadPopulatedGroupListsMembersInFull() async throws {
        let registry = ReadToolRegistry(service: FakeHomeKitService(graph: fixtureGraph()))
        let read = try await deepRead(registry, id: "group-blinds")
        #expect(read.kind == "group")
        #expect(read.id == "group-blinds")
        #expect(read.object.name == "Living Room Blinds")
        #expect(read.object.membershipNote == nil)
        #expect(read.object.services == [
            HomeGraph.ServiceRef(
                id: "svc-blind-right", name: "Right Blind",
                serviceType: Self.windowCoveringType,
                accessoryId: "acc-blinds", accessoryName: "Living Room Blinds"
            ),
        ])
    }

    /// A framework-empty group's deep read carries the explicit note —
    /// never a bare empty list presented as fact.
    @Test func deepReadEmptyGroupCarriesMembershipNote() async throws {
        let registry = ReadToolRegistry(service: FakeHomeKitService(graph: fixtureGraph()))
        let read = try await deepRead(registry, id: "group-debris")
        #expect(read.object.services.isEmpty)
        #expect(read.object.membershipNote == Self.expectedNote)
    }

    // MARK: - Lean summary

    /// The lean summary's group lines carry the same honesty: a populated
    /// group renders its members (ids and names) with no note; an
    /// empty-read group carries the note.
    @Test func leanSummaryGroupsCarryNoteWhenEmpty() async throws {
        let registry = ReadToolRegistry(service: FakeHomeKitService(graph: fixtureGraph()))
        let result = await registry.call(name: "get_details", arguments: nil)
        #expect(!result.isError)
        let projection = try Self.decode(ReadToolRegistry.SummaryProjection.self, from: Self.textContent(result))
        let overview = try #require(projection.homes.first)
        #expect(overview.serviceGroups == [
            ReadToolRegistry.HomeOverview.GroupLine(
                id: "group-blinds", name: "Living Room Blinds",
                services: [ReadToolRegistry.HomeOverview.NameRef(id: "svc-blind-right", name: "Right Blind")],
                membershipNote: nil
            ),
            ReadToolRegistry.HomeOverview.GroupLine(
                id: "group-debris", name: "Living Room Blinds Debris",
                services: [],
                membershipNote: Self.expectedNote
            ),
        ])
    }

    /// The note's wire form is the exact agreed wording — it must survive
    /// JSON encoding for the review card and the agent.
    @Test func membershipNoteSurfacesInWireJSON() async throws {
        let registry = ReadToolRegistry(service: FakeHomeKitService(graph: fixtureGraph()))
        let text = Self.textContent(await registry.call(
            name: "get_details",
            arguments: ["kind": .string("group"), "id": .string("group-debris")]
        ))
        #expect(text.contains(Self.expectedNote))
    }
}
