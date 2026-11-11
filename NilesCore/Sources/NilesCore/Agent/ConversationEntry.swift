import Foundation

/// One transcript row of a Niles conversation (spec art_AL0RolQe). The agent
/// row carries the run's summary verbatim — the same contract as the Siri
/// dialog — plus the ids of the proposals that run staged. Shared by the
/// in-app chat and remote MCP sessions so both surfaces compose history
/// through one code path.
public struct ConversationEntry: Identifiable, Equatable, Sendable {
    public enum Role: Sendable { case user, agent }

    /// A turn's lifecycle: the agent row runs while the request is in
    /// flight, resolves with the summary, or fails with the surfaced error.
    public enum State: Equatable, Sendable {
        case running
        case done
        case failed(String)
    }

    public let id: UUID
    /// When the row was created — the transcript tool interleaves the
    /// in-app and remote conversations by it (spec art_rqDQF7Ic §2).
    public let timestamp: Date
    public let role: Role
    public var text: String
    public var stagedProposalIds: [String] = []
    public var state: State = .done

    public init(
        id: UUID,
        timestamp: Date = Date(),
        role: Role,
        text: String,
        stagedProposalIds: [String] = [],
        state: State = .done
    ) {
        self.id = id
        self.timestamp = timestamp
        self.role = role
        self.text = text
        self.stagedProposalIds = stagedProposalIds
        self.state = state
    }
}

/// Shared turn-resolution rules for every conversation surface — the in-app
/// chat and remote MCP sessions resolve turns identically.
public enum ConversationTranscript {
    /// Resolves the pending agent row in place: the summary and staged ids
    /// land verbatim from the run result.
    public static func resolve(_ id: UUID, in entries: inout [ConversationEntry], result: AgentRunResult) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].text = result.summary
        entries[index].stagedProposalIds = result.stagedProposalIds
        entries[index].state = .done
    }

    /// Marks the pending agent row failed with the shared session-failure
    /// copy — the same wording the Siri dialog uses.
    public static func fail(_ id: UUID, in entries: inout [ConversationEntry], with error: Error) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].state = .failed(AgentRunError.failureMessage(for: error))
    }
}
