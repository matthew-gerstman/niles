import Foundation
import NilesCore
import Observation
import OSLog
import UIKit

/// The home graph's read-only sections and the swipe-to-stage entry: the
/// `HomeGraphViewModel` seam of the former monolithic `LiveNilesStore`
/// (cleanup W3).
///
/// `sections` is written only by `LiveNilesStore.refresh` — the single poll
/// fan-out — through `applySections`; the stage action is this store's own.
@MainActor
@Observable
final class LiveHomeGraphStore: HomeGraphViewModel {

    private(set) var sections: [HomeSection] = []

    private let coordinator: ServerCoordinator

    /// The composition root that owns this store and the shared poll loop.
    /// Weak: the root holds its stores strongly, and both live for the
    /// process lifetime — the reference is wired at the end of the root's
    /// init, before any swipe can run.
    weak var root: LiveNilesStore?

    private let logger = Logger(subsystem: "com.gerstman.niles", category: "live-home-graph")

    init(coordinator: ServerCoordinator) {
        self.coordinator = coordinator
    }

    // MARK: - HomeGraphViewModel / swipe-to-stage

    /// Stages a Home row's swipe action through the same public store path
    /// the agent write tools use, so the swipe produces a normal proposal in
    /// the queue and nothing touches HomeKit until it is approved.
    func stage(row: HomeRow, action: HomeRowAction, newName: String? = nil) async {
        guard let request = row.stageRequest(for: action, newName: newName) else {
            logger.error("No write tool maps to \\(String(describing: action), privacy: .public) on “\\(row.name, privacy: .public)”")
            return
        }
        guard let store = coordinator.proposalStore else {
            logger.error("Cannot stage \\(request.tool, privacy: .public): no proposal store")
            return
        }
        do {
            let proposal = try await store.stage(tool: request.tool, arguments: request.arguments)
            // A swipe is a human action, not an agent's — attribute it as such
            // before the next refresh fills unknown ids with a client name.
            root?.setAgentName("You", for: proposal.id)
            await root?.refresh()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            // Staging rejections (validation, HomeKit state) surface here;
            // nothing was applied either way — the queue stays authoritative.
            logger.error("Staging \\(request.tool, privacy: .public) for “\\(row.name, privacy: .public)” failed: \\(String(describing: error))")
        }
    }

    // MARK: - Poll fan-out (called only by LiveNilesStore.refresh)

    func applySections(_ refreshed: [HomeSection]) {
        sections = refreshed
    }
}
