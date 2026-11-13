import Foundation
import HomeKit
import Testing
@testable import NilesCore

/// The cross-group staging check and the named-HMError evidence — the two
/// fixes the first blind-grouping batch's `HMError 3` failure demanded
/// (spec art_H3kJluSG, PR B items 1–2).
///
/// The staging rule runs twice on purpose (the `valueViolation` pattern):
/// the planner rejects the member-add before a proposal exists, and the
/// device resolver rejects it again at execution against the live view.
/// The evidence rule maps common `HMError` codes to meaning while never
/// losing the raw error.
///
/// Follows the PR #15 validation-test pattern: pure fixtures over
/// `DeviceHomeView` and `HomeGraph`, no `HMHomeManager`.
@Suite struct ServiceGroupStagingHardeningTests {

    // MARK: - Fixtures

    private static let windowCovering = "0000006C-0000-1000-8000-0026BB765291"

    /// The device view the executor resolves against: one blind accessory
    /// with "Right" already grouped and "Center" ungrouped.
    private func fixtureView() -> DeviceHomeView {
        var view = DeviceHomeView()
        view.homes = [
            DeviceHomeView.Home(
                id: "home-1", name: "Townhouse",
                rooms: [DeviceHomeView.Room(id: "room-living", name: "Living Room", accessoryIds: ["acc-blinds"])],
                serviceGroups: [
                    DeviceHomeView.ServiceGroup(id: "group-living", name: "Living Room Blinds", serviceIds: ["svc-right"]),
                    DeviceHomeView.ServiceGroup(id: "group-bedroom", name: "Bedroom Blinds", serviceIds: []),
                ],
                accessories: [DeviceHomeView.Accessory(
                    id: "acc-blinds", name: "Blinds", supportsIdentify: true,
                    services: [
                        DeviceHomeView.Service(
                            id: "svc-right", name: "Right", serviceType: Self.windowCovering, characteristics: []
                        ),
                        DeviceHomeView.Service(
                            id: "svc-center", name: "Center", serviceType: Self.windowCovering, characteristics: []
                        ),
                    ]
                )]
            )
        ]
        return view
    }

    /// The graph the planner plans against — the same shape the read side
    /// projects, with group membership visible.
    private func fixtureGraph() -> HomeGraph {
        let right = HomeGraph.AccessoryService(
            id: "svc-right", name: "Right", serviceType: Self.windowCovering, characteristics: []
        )
        let center = HomeGraph.AccessoryService(
            id: "svc-center", name: "Center", serviceType: Self.windowCovering, characteristics: []
        )
        let blinds = HomeGraph.Accessory(
            id: "acc-blinds", name: "Blinds", reachable: true, bridged: false,
            category: "com.apple.hap.window-covering", services: [right, center]
        )
        let living = HomeGraph.Room(id: "room-living", name: "Living Room", accessories: [blinds])
        let livingGroup = HomeGraph.ServiceGroup(
            id: "group-living", name: "Living Room Blinds",
            services: [HomeGraph.ServiceRef(
                id: "svc-right", name: "Right", serviceType: Self.windowCovering,
                accessoryId: "acc-blinds", accessoryName: "Blinds"
            )]
        )
        let bedroomGroup = HomeGraph.ServiceGroup(id: "group-bedroom", name: "Bedroom Blinds", services: [])
        let home = HomeGraph.Home(id: "home-1", name: "Townhouse", rooms: [living], serviceGroups: [livingGroup, bedroomGroup])
        return HomeGraph(homes: [home])
    }

    /// Runs a planner request expected to fail; returns the planner error,
    /// or records an issue and returns nil when nothing was thrown.
    private func plannerError(
        sourceLocation: SourceLocation = #_sourceLocation, _ body: () throws -> Void
    ) -> ProposalPlanner.PlannerError? {
        do {
            try body()
            Issue.record("expected planning to fail", sourceLocation: sourceLocation)
            return nil
        } catch {
            #expect(error is ProposalPlanner.PlannerError, "\(error)", sourceLocation: sourceLocation)
            return error as? ProposalPlanner.PlannerError
        }
    }

    private static let hmError3 = NSError(domain: HMErrorDomain, code: 3)

    // MARK: - Staging: the cross-group rule (planner half)

    @Test func plannerRejectsMemberAddToForeignGroup() throws {
        guard case .invalidInput(let message)? = plannerError({
            _ = try ProposalPlanner.plan(
                .setServiceGroupMembers(groupId: "group-bedroom", serviceIds: ["svc-right"]),
                graph: fixtureGraph()
            )
        }) else { return }
        #expect(message == "Right already belongs to group “Living Room Blinds”. Remove it there first.")
    }

    @Test func plannerPassesCleanMemberAdd() throws {
        let plan = try ProposalPlanner.plan(
            .setServiceGroupMembers(groupId: "group-bedroom", serviceIds: ["svc-center"]),
            graph: fixtureGraph()
        )
        #expect(plan.tool == "set_service_group_members")
        #expect(plan.operations == [.setServiceGroupMembers(
            homeId: "home-1", groupId: "group-bedroom", addServiceIds: ["svc-center"], removeServiceIds: []
        )])
    }

    @Test func plannerPassesReAddToItsOwnGroup() throws {
        // "Right" is a member of "Living Room Blinds" and is being set into
        // that same group — no foreign membership, so this stages; the diff
        // makes it a no-op.
        guard case .noChange? = plannerError({
            _ = try ProposalPlanner.plan(
                .setServiceGroupMembers(groupId: "group-living", serviceIds: ["svc-right"]),
                graph: fixtureGraph()
            )
        }) else { return }
    }

    @Test func plannerRejectsCreateGroupWithAlreadyGroupedService() throws {
        guard case .invalidInput(let message)? = plannerError({
            _ = try ProposalPlanner.plan(
                .createServiceGroup(homeId: "home-1", name: "All Blinds", serviceIds: ["svc-right"]),
                graph: fixtureGraph()
            )
        }) else { return }
        #expect(message == "Right already belongs to group “Living Room Blinds”. Remove it there first.")
    }

    @Test func plannerPassesCreateGroupWithUngroupedServices() throws {
        let plan = try ProposalPlanner.plan(
            .createServiceGroup(homeId: "home-1", name: "All Blinds", serviceIds: ["svc-center"]),
            graph: fixtureGraph()
        )
        #expect(plan.tool == "create_service_group")
    }

    // MARK: - Staging: the cross-group rule (resolver half)

    @Test func resolverRejectsMemberAddToForeignGroup() {
        #expect(throws: HomeKitWriteError.invalidOperation(
            "Right already belongs to group “Living Room Blinds”. Remove it there first."
        )) {
            try DeviceWriteResolver.resolve(
                .setServiceGroupMembers(homeId: "home-1", groupId: "group-bedroom", addServiceIds: ["svc-right"], removeServiceIds: []),
                in: fixtureView()
            )
        }
    }

    @Test func resolverPassesCleanMemberAdd() throws {
        let steps = try DeviceWriteResolver.resolve(
            .setServiceGroupMembers(homeId: "home-1", groupId: "group-bedroom", addServiceIds: ["svc-center"], removeServiceIds: []),
            in: fixtureView()
        )
        #expect(steps == [.updateServiceGroupMembers(
            homeId: "home-1", groupId: "group-bedroom", addServiceIds: ["svc-center"], removeServiceIds: []
        )])
    }

    @Test func resolverRejectsCreateGroupWithAlreadyGroupedService() {
        #expect(throws: HomeKitWriteError.invalidOperation(
            "Right already belongs to group “Living Room Blinds”. Remove it there first."
        )) {
            try DeviceWriteResolver.resolve(
                .addServiceGroup(homeId: "home-1", name: "All Blinds", serviceIds: ["svc-right"]),
                in: fixtureView()
            )
        }
    }

    @Test func resolverPassesCreateGroupWithUngroupedServices() throws {
        let steps = try DeviceWriteResolver.resolve(
            .addServiceGroup(homeId: "home-1", name: "All Blinds", serviceIds: ["svc-center"]),
            in: fixtureView()
        )
        #expect(steps == [.addServiceGroup(homeId: "home-1", name: "All Blinds", serviceIds: ["svc-center"])])
    }

    // MARK: - Evidence: named HMError wording

    @Test func hmError3RendersNamedMeaningAndRaw() {
        let message = HomeKitErrorNarrative.describe(Self.hmError3)
        #expect(message.contains("HMError 3"))
        #expect(message.contains("invalidParameter"))
        // The raw error never goes away — it rides after the meaning.
        #expect(message.contains(String(describing: Self.hmError3)))
    }

    @Test func hmError26KeepsTriggerMeaning() {
        let message = HomeKitErrorNarrative.describe(NSError(domain: HMErrorDomain, code: 26))
        #expect(message.contains("HMError 26"))
        #expect(message.contains("action sets"))
        #expect(message.contains(String(describing: NSError(domain: HMErrorDomain, code: 26))))
    }

    @Test func unmappedErrorStandsAlone() {
        struct FixtureError: Error {}
        let error = FixtureError()
        #expect(HomeKitErrorNarrative.describe(error) == String(describing: error))
        #expect(HomeKitErrorNarrative.meaning(for: error) == nil)
    }

    @Test func groupRefusalNamesServiceAndGroup() {
        let message = HomeKitErrorNarrative.groupRefusal(
            service: "Right", group: "Living Room Blinds", error: Self.hmError3
        )
        #expect(message == "HomeKit refused “Right” as a member of group “Living Room Blinds”: "
            + "HomeKit rejected this call as invalid (HMError 3, invalidParameter) — HomeKit reported: "
            + String(describing: Self.hmError3))
    }

    @Test func writeErrorRendersItsMessage() {
        #expect(String(describing: HomeKitWriteError.invalidOperation("boom")) == "boom")
    }

    // MARK: - The window-covering known-unknown (diagnostic verdict: categorical)

    /// A non-covering service for the quiet-path assertions.
    private static let lightbulb = "00000043-0000-1000-8000-0026BB765291"

    /// The graph fixture gains one lightbulb service; existing tests above
    /// never enumerate services, so the addition is inert for them.
    private func fixtureGraphWithLight() -> HomeGraph {
        var graph = fixtureGraph()
        var blinds = graph.homes[0].rooms[0].accessories[0]
        blinds.services.append(HomeGraph.AccessoryService(
            id: "svc-light", name: "Lamp", serviceType: Self.lightbulb, characteristics: []
        ))
        graph.homes[0].rooms[0].accessories[0] = blinds
        return graph
    }

    private static let warningText = "HomeKit may refuse this membership change"

    @Test func membershipCardWarnsOnWindowCoveringAdd() throws {
        let plan = try ProposalPlanner.plan(
            .setServiceGroupMembers(groupId: "group-bedroom", serviceIds: ["svc-center"]),
            graph: fixtureGraph()
        )
        let warned = plan.card.contains { line in
            line.kind == .note && line.text.contains(Self.warningText)
        }
        #expect(warned)
    }

    @Test func membershipCardStaysQuietForNonCoveringAdd() throws {
        let plan = try ProposalPlanner.plan(
            .setServiceGroupMembers(groupId: "group-bedroom", serviceIds: ["svc-light"]),
            graph: fixtureGraphWithLight()
        )
        let warned = plan.card.contains { line in
            line.text.contains(Self.warningText)
        }
        #expect(!warned)
    }

    @Test func createGroupCardWarnsOnWindowCoveringMembers() throws {
        let plan = try ProposalPlanner.plan(
            .createServiceGroup(homeId: "home-1", name: "All Blinds", serviceIds: ["svc-center"]),
            graph: fixtureGraph()
        )
        let warned = plan.card.contains { line in
            line.kind == .note && line.text.contains(Self.warningText)
        }
        #expect(warned)
    }

    @Test func createGroupWithoutMembersCarriesNoWarning() throws {
        let plan = try ProposalPlanner.plan(
            .createServiceGroup(homeId: "home-1", name: "Empty Group", serviceIds: []),
            graph: fixtureGraph()
        )
        let warned = plan.card.contains { line in
            line.text.contains(Self.warningText)
        }
        #expect(!warned)
    }
}
