import Foundation

/// The single on-device agent feature gate (approved initial-ship choice):
/// the whole agent — the Niles chat tab and the Ask Niles App Intent — sits
/// behind one switch. Bundled OFF in Release (the agent ships dark) and ON
/// in DEBUG so dogfooding needs no settings trip.
///
/// Backed by `UserDefaults` (the store `@AppStorage` reads): the Settings
/// toggle binds through `@AppStorage(AgentGate.storageKey)` so SwiftUI
/// re-renders consumers live — toggling on restores the chat tab without a
/// relaunch — while non-view callers (`AskNilesRouter`) read `isEnabled`
/// from the same store.
enum AgentGate {
    /// The `UserDefaults` key the Settings toggle and every reader share.
    static let storageKey = "agent.enabled"

    /// What a fresh install reports before the toggle is ever touched:
    /// ON in DEBUG, OFF in Release. A compile-time choice, not a stored one —
    /// the key stays unset until the user toggles.
    static var bundledDefault: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// The gate's current state. A never-set key falls back to the bundled
    /// default, so first launch matches the ship decision before any write.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: storageKey) as? Bool ?? bundledDefault
    }

    /// Simulator QA fixture (`-UIAgentGateToggle`, same family as
    /// `-UISeedQueue`/`-UIChatFixtures`): flips the gate in-process a few
    /// seconds after launch — the same `UserDefaults` write the Settings
    /// toggle performs — so a capture pair shows the tab row re-rendering
    /// live, without a relaunch. No-op without the argument.
    static func toggleFixtureIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-UIAgentGateToggle") else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            UserDefaults.standard.set(!isEnabled, forKey: storageKey)
        }
    }
}
