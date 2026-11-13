import Foundation
import NilesCore
import Observation
import OSLog

/// The on-device agent's availability, usage, and runner — the
/// `AgentStatusViewModel` seam of the former monolithic `LiveNilesStore`
/// (cleanup W3). Both entry points read it: the chat composes through
/// `agentRunner`, and the Siri intent reads the same runner off the shared
/// composition root, so availability is decided exactly once.
///
/// `refreshUsage()` is the poll fan-out's per-tick update.
@MainActor
@Observable
final class LiveAgentStatusStore: AgentStatusViewModel {

    /// Evaluated once at feature entry (spec art_VrC0iUUA §Availability
    /// gate): the agent is either fully available or states why not — never
    /// a degraded mode.
    private(set) var agentAvailability = AgentAvailability.unavailable(.needsIOS27)
    /// Session usage, refreshed with the poll from the runner when one
    /// exists. Zero until the first request runs.
    private(set) var agentUsage = AgentSessionUsage()
    /// The on-device agent's runner, non-nil only when the gate passed. No
    /// agent path is enterable when this is nil — Settings states the
    /// reason instead.
    private(set) var agentRunner: (any AgentRunning)?

    init(
        agentRunner: (any AgentRunning)? = nil,
        agentAvailability: AgentAvailability? = nil,
        coordinator: ServerCoordinator
    ) {
        // Test seams: an injected runner is available by definition (chat
        // tests drive the live store without Apple Intelligence hardware);
        // production callers take the defaults and the gate decides.
        if let injected = agentAvailability {
            self.agentAvailability = injected
        } else if agentRunner != nil {
            self.agentAvailability = .available
        } else {
            self.agentAvailability = Self.evaluateAgentAvailability()
        }
        if let runner = agentRunner {
            self.agentRunner = runner
        } else if case .available = self.agentAvailability,
                  #available(iOS 27.0, *),
                  let proposalStore = coordinator.proposalStore {
            self.agentRunner = AgentService(store: proposalStore)
        }
    }

    /// The one availability check, at the one feature entry this app has.
    /// The gate itself is iOS 26+ (Foundation Models); below that the OS
    /// bar already fails the agent core's iOS 27 requirement.
    private static func evaluateAgentAvailability() -> AgentAvailability {
        if #available(iOS 26.0, *) {
            return AgentAvailabilityGate.evaluate()
        }
        return .unavailable(.needsIOS27)
    }

    // MARK: - Poll fan-out (called only by LiveNilesStore.refresh)

    func refreshUsage() async {
        if let runner = agentRunner {
            agentUsage = await runner.usage
        }
    }
}
