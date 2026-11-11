import Foundation
import NilesCore
import Observation

/// The in-app chat surface's view model (spec art_AL0RolQe). Each send is
/// one independent `AgentRunning.run(_:)` — the same seam Siri composes
/// through — so a message can stage proposals but never approve or execute
/// them. Follow-ups ride a bounded window of completed transcript rows
/// composed into the request string (ConversationContext); no memory
/// survives a fresh app launch.
@MainActor
protocol ChatViewModel: Observable {
    /// The transcript, oldest first.
    var entries: [ConversationEntry] { get }
    /// The runner is available and no run is in flight — the composer's
    /// enabled state.
    var canSend: Bool { get }
    /// Appends the user's message, awaits the run, and resolves the agent
    /// row from the result. Ignored while a run is in flight.
    func send(_ text: String) async
}

// MARK: - Preview fixture

// The fixture's `send` lives in the class body of `InMemoryNilesStore`
// (NilesViewModels.swift) — its `private(set)` transcript storage is only
// mutable there, and widening it for one method would loosen the model for
// every caller.
