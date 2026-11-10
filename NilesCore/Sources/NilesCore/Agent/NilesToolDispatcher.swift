import Foundation
import MCP

/// The in-process proxy between the on-device language model and the tool
/// registries. Every tool call the model makes goes through exactly one
/// dispatcher, which:
///
/// - routes the call to `ReadToolRegistry` or `WriteToolRegistry` by name,
/// - enforces a mechanical per-request call budget (exhaustion is an in-band
///   `isError` result, never a thrown error),
/// - caps any single tool response so one read cannot flood the context
///   window, and
/// - records the proposal ids each successful write stages.
///
/// An actor because the model's tool calls can interleave; the budget and the
/// staged-id log must stay exact under concurrency.
public actor NilesToolDispatcher {
    /// One dispatched call, flattened for the toolset layer.
    public struct Outcome: Sendable, Equatable {
        public var text: String
        public var isError: Bool
        /// The proposal this call staged, if it was a successful write.
        public var stagedProposalId: String?
    }

    /// How much of the budget one request may spend across all tools.
    public let budget: Int
    /// Serialized-response ceiling; ~1,000 tokens of text (≈4 chars/token).
    public let responseCharacterLimit: Int

    /// Every call the model attempted, in order. Failed and budget-exhausted
    /// calls are included so the agent can report what actually happened.
    public private(set) var attemptedCalls: [AttemptedCall] = []
    /// Proposal ids staged by successful write calls, in staging order.
    public private(set) var stagedProposalIds: [String] = []
    /// Calls refused because the budget was already spent.
    public private(set) var budgetExhaustions = 0

    public struct AttemptedCall: Sendable, Equatable {
        public var tool: String
        public var isError: Bool
        public var wasBudgetExhausted: Bool
    }

    private let reads: ReadToolRegistry
    private let writes: WriteToolRegistry
    private let readNames: Set<String>
    private let writeNames: Set<String>
    private let proposalIdExtraction: @Sendable (CallTool.Result) -> String?

    /// Every registry tool definition, in registry order — the toolset
    /// generator's source of truth. A fixed snapshot, so the toolset can be
    /// built without entering the actor.
    public let toolDefinitions: [MCP.Tool]

    public init(
        reads: ReadToolRegistry,
        writes: WriteToolRegistry,
        budget: Int = NilesToolDispatcher.defaultBudget,
        responseCharacterLimit: Int = NilesToolDispatcher.defaultResponseCharacterLimit
    ) {
        self.reads = reads
        self.writes = writes
        self.readNames = Set(reads.toolNames)
        self.writeNames = Set(writes.toolNames)
        self.budget = budget
        self.responseCharacterLimit = responseCharacterLimit
        self.proposalIdExtraction = Self.proposalId(in:)
        self.toolDefinitions = reads.toolDefinitions + writes.toolDefinitions
    }

    public static let defaultBudget = 12
    public static let defaultResponseCharacterLimit = 4_000

    /// Dispatches one tool call. Never throws and never returns a thrown
    /// error to the caller: every failure mode — unknown tool, invalid
    /// arguments, planner rejection, budget exhaustion — comes back as an
    /// in-band `isError` result, because a thrown error would abort the
    /// whole session instead of teaching the model what went wrong.
    public func call(name: String, arguments: [String: Value]? = nil) async -> Outcome {
        if attemptedCalls.count >= budget {
            budgetExhaustions += 1
            attemptedCalls.append(AttemptedCall(tool: name, isError: true, wasBudgetExhausted: true))
            return Outcome(
                text: Self.budgetExhaustedMessage(tool: name, budget: budget),
                isError: true,
                stagedProposalId: nil
            )
        }

        let result: CallTool.Result
        // Read tools first; the two registries' name sets do not overlap.
        // An unknown name routes to the write registry so the caller sees
        // exactly the error a direct write-registry call would produce.
        if readNames.contains(name) {
            result = await reads.call(name: name, arguments: arguments)
        } else {
            result = await writes.call(name: name, arguments: arguments)
        }

        let text = Self.serializedText(of: result, limit: responseCharacterLimit)
        let isError = result.isError == true
        let stagedId: String?
        if !isError, writeNames.contains(name), name != Self.proposalPollToolName {
            stagedId = proposalIdExtraction(result)
            if let stagedId { stagedProposalIds.append(stagedId) }
        } else {
            stagedId = nil
        }
        attemptedCalls.append(AttemptedCall(tool: name, isError: isError, wasBudgetExhausted: false))
        return Outcome(text: text, isError: isError, stagedProposalId: stagedId)
    }

    /// `get_proposal` lives in the write registry but reads state — it stages
    /// nothing, so it must not count as a staged write.
    static let proposalPollToolName = "get_proposal"

    public static func budgetExhaustedMessage(tool: String, budget: Int) -> String {
        "Budget exhausted: the per-request tool budget of \(budget) calls is spent, so \"\(tool)\" was not run. Stop calling tools and report to the user exactly what you completed, what you did not, and why."
    }

    /// Joins the result's text parts — both registries emit a single text
    /// part — and caps the length with an explicit truncation marker.
    static func serializedText(of result: CallTool.Result, limit: Int) -> String {
        let text = result.content.compactMap { part -> String? in
            if case .text(let text) = part { return text.text }
            return nil
        }.joined(separator: "\n")
        guard text.count > limit else { return text }
        let marker = "… [truncated by Niles: response exceeded the \(limit)-character cap; narrow the request (roomId/accessoryId on get_rooms) and call again]"
        return String(text.prefix(limit)) + marker
    }

    /// Successful write results mirror the staged `Proposal` in their
    /// structured content; its `id` is what the runner reports back.
    static func proposalId(in result: CallTool.Result) -> String? {
        guard case .object(let fields) = result.structuredContent else { return nil }
        guard case .string(let id) = fields["id"] else { return nil }
        return id
    }
}
