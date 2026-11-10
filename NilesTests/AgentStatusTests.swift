import Foundation
import NilesCore
import Testing
@testable import Niles

/// The agent status surface: the store's feature-entry wiring (a runner
/// exists exactly when the gate says available) and the Settings text for
/// every gate state.
@MainActor
struct AgentStatusTests {

    /// A per-test temp log — same isolation as LiveNilesStoreTests.
    private func isolatedActivityLog() -> ActivityLog {
        ActivityLog(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("niles-activity-\(UUID().uuidString)", isDirectory: true))
    }

    @Test
    func runnerExistsExactlyWhenTheGateSaysAvailable() {
        let fake = FakeHomeKitService(graph: .demoFixture)
        let coordinator = ServerCoordinator(tokenStore: StaticTokenStore(token: "test-token"), homeKitService: fake)
        let store = LiveNilesStore(coordinator: coordinator, notifier: .disabled, activityLog: isolatedActivityLog())

        // Evaluated at feature entry, once: whichever way the gate reads on
        // this runtime, the composition never disagrees with it. On an
        // unavailable state no agent path exists at all.
        switch store.agentAvailability {
        case .available:
            #expect(store.agentRunner != nil)
        case .unavailable:
            #expect(store.agentRunner == nil)
        }
        #expect(store.agentUsage == AgentSessionUsage(), "no requests have run")
    }

    @Test
    func statusLabelCoversEveryGateState() {
        #expect(SettingsScreen.agentStatusLabel(.available) == "Available")
        #expect(SettingsScreen.agentStatusLabel(.unavailable(.needsIOS27)) == "Needs iOS 27")
        #expect(SettingsScreen.agentStatusLabel(.unavailable(.deviceNotEligible)) == "Device not eligible")
        #expect(SettingsScreen.agentStatusLabel(.unavailable(.appleIntelligenceNotEnabled)) == "Apple Intelligence off")
        #expect(SettingsScreen.agentStatusLabel(.unavailable(.modelNotReady)) == "Model not ready")
        #expect(SettingsScreen.agentStatusLabel(.unavailable(.unknown)) == "Unavailable")
    }

    @Test
    func footerStatesTheReasonAndNeverImpliesAFallback() {
        // The no-degraded-mode invariant: an unavailable state explains what
        // is missing; nothing suggests a cloud-backed or weaker mode exists.
        for case .unavailable(let reason) in [
            AgentAvailability.unavailable(.needsIOS27),
            .unavailable(.deviceNotEligible),
            .unavailable(.appleIntelligenceNotEnabled),
            .unavailable(.modelNotReady),
            .unavailable(.unknown),
        ] {
            let footer = SettingsScreen.agentFooterText(.unavailable(reason))
            #expect(!footer.isEmpty)
            #expect(footer.range(of: "fallback", options: .caseInsensitive) == nil)
            #expect(footer.range(of: "cloud", options: .caseInsensitive) == nil)
        }
        #expect(
            SettingsScreen.agentFooterText(.available).contains("Queue"),
            "the available-state footer restates the staging contract"
        )
    }
}
