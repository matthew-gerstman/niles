import Foundation
import NilesCore
import Observation
import OSLog
import UIKit

/// The persisted answer to the first-open serving consent prompt. The state
/// space is fixed by the serving-consent spec: `unset` (fresh install) means
/// prompt on open; `approved` means serve when foregrounded unless the user
/// stopped the server; `denied` means never serve automatically — the Serving
/// toggle is the only re-enable path. Denial is never re-prompted.
enum ServingApproval: String {
    case unset
    case approved
    case denied
}

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

    /// The consent answer, persisted across launches (defaults). Written by
    /// `setServerRunning` and the consent sheet's answer; read by the scene
    /// handoff's serving guard and the first-open sheet's presentation.
    private(set) var servingApproval: ServingApproval = LiveDashboardStore.loadApproval()

    /// The scene-handoff serving guard: foregrounded AND consented AND not
    /// user-stopped. One gate — `LANServer.start()` binds the port and
    /// registers `_niles-mcp._tcp` atomically.
    var mayAutoServe: Bool {
        servingApproval == .approved && !userStoppedServer
    }

    /// The consent sheet presents until the question is answered (first open
    /// on a fresh install; the persisted answer is never re-asked).
    var needsServingConsent: Bool {
        servingApproval == .unset
    }

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
    /// unregisters Bonjour; on resumes serving while foregrounded. The
    /// toggle is also a consent surface: turning it on records approval,
    /// off records denial — both persisted, so a relaunch never auto-serves
    /// after the user switched serving off.
    func setServerRunning(_ running: Bool) {
        userStoppedServer = !running
        setServingApproval(running ? .approved : .denied)
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

    // MARK: - Serving consent

    /// The consent sheet's Approve action: records approval and starts
    /// serving immediately — the user action that anchors the iOS
    /// local-network permission prompt.
    func recordServingConsentApproved() {
        setServingApproval(.approved)
        setServerRunning(true)
    }

    /// The consent sheet's Not Now action: records denial. Serving stays
    /// off and the prompt never returns; the Serving toggle re-enables.
    func recordServingConsentDenied() {
        setServingApproval(.denied)
    }

    private func setServingApproval(_ approval: ServingApproval) {
        servingApproval = approval
        UserDefaults.standard.set(approval.rawValue, forKey: Self.approvalKey)
    }

    private static let approvalKey = "servingApproval"

    /// The persisted answer, or `.unset` on a fresh install. Capture fixtures
    /// and test hosts never consent — they predate the prompt and their
    /// captures (and test runs) must not be blocked by a sheet, so they read
    /// as approved without writing defaults. `-UIServingConsent
    /// <approved|denied|unset>` seeds the answer for relaunch captures: the
    /// same code path as a real answer, no UI automation needed.
    private static func loadApproval() -> ServingApproval {
        if let seeded = LaunchArguments.uiServingConsent {
            let seeded = ServingApproval(rawValue: seeded.lowercased()) ?? .unset
            if seeded != .unset {
                UserDefaults.standard.set(seeded.rawValue, forKey: approvalKey)
            }
            return seeded
        }
        if LaunchArguments.isCaptureFixture || LaunchArguments.isTestHost {
            return .approved
        }
        return UserDefaults.standard.string(forKey: approvalKey).flatMap(ServingApproval.init(rawValue:)) ?? .unset
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
