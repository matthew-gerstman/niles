import Foundation
import NilesCore
import Observation

/// One transcript row of the in-app chat (spec art_AL0RolQe). The agent row
/// carries the run's summary verbatim — the same contract as the Siri
/// dialog — plus the ids of the proposals that run staged.
struct ChatEntry: Identifiable, Equatable {
    enum Role { case user, agent }

    /// A turn's lifecycle: the agent row runs while the request is in
    /// flight, resolves with the summary, or fails with the surfaced error.
    enum State: Equatable {
        case running
        case done
        case failed(String)
    }

    let id: UUID
    let role: Role
    var text: String
    var stagedProposalIds: [String] = []
    var state: State = .done
}

/// The in-app chat surface's view model (spec art_AL0RolQe). Each send is
/// one independent `AgentRunning.run(_:)` — the same seam Siri composes
/// through — so a message can stage proposals but never approve or execute
/// them. No cross-request context: follow-ups are new requests.
@MainActor
protocol ChatViewModel: Observable {
    /// The transcript, oldest first.
    var entries: [ChatEntry] { get }
    /// The runner is available and no run is in flight — the composer's
    /// enabled state.
    var canSend: Bool { get }
    /// Appends the user's message, awaits the run, and resolves the agent
    /// row from the result. Ignored while a run is in flight.
    func send(_ text: String) async
}

/// Shared turn-resolution rules for every `ChatViewModel` conformer — the
/// live store and the preview fixture resolve turns identically.
enum ChatTranscript {
    /// Resolves the pending agent row in place: the summary and staged ids
    /// land verbatim from the run result.
    static func resolve(_ id: UUID, in entries: inout [ChatEntry], result: AgentRunResult) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].text = result.summary
        entries[index].stagedProposalIds = result.stagedProposalIds
        entries[index].state = .done
    }

    /// Marks the pending agent row failed with the shared session-failure
    /// copy — the same wording the Siri dialog uses.
    static func fail(_ id: UUID, in entries: inout [ChatEntry], with error: Error) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].state = .failed(AskNilesRouter.failureMessage(for: error))
    }
}

// MARK: - Preview fixture

// The fixture's `send` lives in the class body of `InMemoryNilesStore`
// (NilesViewModels.swift) — its `private(set)` transcript storage is only
// mutable there, and widening it for one method would loosen the model for
// every caller.
