import Foundation
import NilesCore
import Observation
import OSLog
import UIKit

/// The Home tab's server state: serving status, endpoint, connected agents,
/// and the home's display name — the `DashboardViewModel` seam of the former
/// monolithic `LiveNilesStore`, split out per protocol seam (cleanup W3).
///
/// Also owns the server kill switch and the scene-phase bookkeeping: the
/// toggle is this seam's state, and the composition root's scene handoff
/// reads both when deciding whether serving may resume.
///
/// State is written in exactly two places: this store's own actions, and
/// `LiveNilesStore.refresh` — the single poll fan-out — through the `apply*`
/// methods below.
@MainActor
@Observable
final class LiveDashboardStore: DashboardViewModel {

    private(set) var homeName = "No home"
    private(set) var serverIsRunning = false
    private(set) var endpoint = ""
    private(set) var bonjourService = "\(NilesBonjour.serviceType).local"
    private(set) var connectedAgents: [AgentConnection] = []

    /// The user's kill switch (spec: the server toggle doubles as one). While
    /// set, foregrounding the app does not restart serving.
    private(set) var userStoppedServer = false

    /// Set from the scene phase handoff in `LiveNilesStore.handleScene(isActive:)`;
    /// the keep-awake policy only holds the screen up while the app is frontmost.
    private(set) var isAppActive = false

    private let coordinator: ServerCoordinator

    /// The composition root that owns this store and the shared poll loop.
    /// Weak: the root holds its stores strongly, and both live for the
    /// process lifetime — the reference is wired at the end of the root's
    /// init, before any action can run.
    weak var root: LiveNilesStore?

    private let logger = Logger(subsystem: "com.gerstman.niles", category: "live-dashboard")

    init(coordinator: ServerCoordinator) {
        self.coordinator = coordinator
        endpoint = "http://\(LANAddress.primaryIPv4 ?? "127.0.0.1"):\(LANServer.defaultPort)/mcp"
    }

    // MARK: - DashboardViewModel

    /// The server toggle's kill switch: off closes every connection and
    /// unregisters Bonjour; on resumes serving while foregrounded.
    func setServerRunning(_ running: Bool) {
        userStoppedServer = !running
        serverIsRunning = running
        Task {
            if running {
                await coordinator.start()
            } else {
                await coordinator.stop()
            }
            await root?.refresh()
        }
    }

    // MARK: - Scene phase (called by the composition root)

    /// The scene-phase handoff's active flag, mirrored here so the keep-awake
    /// policy evaluates with the same inputs the monolithic store used. The
    /// policy itself is applied by the handoff's trailing refresh.
    func applySceneActive(_ active: Bool) {
        isAppActive = active
    }

    // MARK: - Poll fan-out (called only by LiveNilesStore.refresh)

    /// The endpoint and serving state, in the refresh order the monolithic
    /// store used (endpoint, serving state, then the keep-awake policy).
    func applyServerState() {
        endpoint = "http://\(LANAddress.primaryIPv4 ?? "127.0.0.1"):\(LANServer.defaultPort)/mcp"
        serverIsRunning = coordinator.status.isRunning
        applyIdleTimerPolicy()
    }

    func applySessions(_ sessions: [MCPGateway.SessionInfo]) {
        connectedAgents = sessions.map { session in
            AgentConnection(
                name: session.clientName ?? "Unknown client",
                detail: "Streamable HTTP · last seen \(RelativeTime.label(for: session.lastAccessedAt))",
                isActive: Date().timeIntervalSince(session.lastAccessedAt) < 30
            )
        }
    }

    func applyHomeName(_ name: String) {
        homeName = name
    }

    /// Serving keeps the screen awake (a locked phone suspends the LAN
    /// server); stopping the server or backgrounding restores normal auto-lock.
    private func applyIdleTimerPolicy() {
        UIApplication.shared.isIdleTimerDisabled = IdleTimerPolicy.shouldKeepScreenAwake(
            isServing: serverIsRunning,
            isAppActive: isAppActive
        )
    }
}
