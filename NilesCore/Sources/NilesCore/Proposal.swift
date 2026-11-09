import Foundation

/// Which configuration object a diff entry touches (the spec's object ref).
public struct ProposalObjectRef: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case room, zone, scene, serviceGroup, accessory, trigger
    }

    public let kind: Kind
    /// Empty for creates — the id does not exist until approval runs.
    public let id: String
    public let name: String?

    public init(kind: Kind, id: String, name: String?) {
        self.kind = kind
        self.id = id
        self.name = name
    }
}

/// One per-object change in a proposal (the spec's `ProposalDiff`): what
/// object, what operation, and the human-readable before/after values.
public struct ProposalDiffEntry: Codable, Sendable, Equatable, Hashable {
    public enum Op: String, Codable, Sendable {
        case create, rename, delete, move, addMembers, removeMembers, update
    }

    public let object: ProposalObjectRef
    public let op: Op
    public let before: String?
    public let after: String?

    public init(object: ProposalObjectRef, op: Op, before: String?, after: String?) {
        self.object = object
        self.op = op
        self.before = before
        self.after = after
    }
}

/// A rendered line of the review card, mirroring the mockup's diff styling:
/// additions green, removals red, warnings amber, context neutral.
public struct ProposalCardLine: Codable, Sendable, Equatable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case add, remove, note, plain
    }

    public let kind: Kind
    public let text: String

    public init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

/// The staging dry-check outcome (the spec's `ValidationResult`). Invalid
/// proposals are rejected before a human sees a card, so stored proposals
/// always record a passing check.
public struct ProposalValidation: Codable, Sendable, Equatable, Hashable {
    public let passed: Bool
    /// Per-action details when the check failed; empty when it passed.
    public let messages: [String]

    public init(passed: Bool, messages: [String] = []) {
        self.passed = passed
        self.messages = messages
    }

    public static let passed = ProposalValidation(passed: true)
}

/// Post-execution read-back (the spec's `Evidence`): what the change claimed,
/// what the home actually showed afterwards, and whether they agree.
/// `confirmed` is computed from the re-read graph, never declared — evidence
/// that merely sounds right is not evidence.
public struct ProposalEvidence: Codable, Sendable, Equatable, Hashable {
    public let claim: String
    public let observed: String
    public let confirmed: Bool

    public init(claim: String, observed: String, confirmed: Bool) {
        self.claim = claim
        self.observed = observed
        self.confirmed = confirmed
    }
}

/// The proposal envelope every mutating tool stages (the spec's `Proposal`).
///
/// Nothing here mutates HomeKit — it is the review-card payload the agent's
/// request turns into. The store is the only writer of the mutable fields.
public struct Proposal: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let tool: String
    public let title: String
    /// One-line, human-readable summary ("Create scene 'Movie Night' with 3 actions").
    public let summary: String
    /// Destructive proposals (room/scene/group deletion) get the danger
    /// treatment on the card.
    public let isDestructive: Bool
    public let entries: [ProposalDiffEntry]
    /// Rendered review-card lines, including blast-radius notes.
    public let card: [ProposalCardLine]
    public let validation: ProposalValidation
    public let createdAt: Date
    public let expiresAt: Date
    public internal(set) var state: ProposalState
    public internal(set) var evidence: [ProposalEvidence]
    public internal(set) var error: String?
    /// Set on a revert proposal: the id of the executed proposal this
    /// proposal's operations undo. Nil for every normally staged proposal.
    public internal(set) var revertsProposalId: String? = nil

    public init(
        id: String,
        tool: String,
        title: String,
        summary: String,
        isDestructive: Bool,
        entries: [ProposalDiffEntry],
        card: [ProposalCardLine],
        validation: ProposalValidation,
        createdAt: Date,
        expiresAt: Date
    ) {
        self.id = id
        self.tool = tool
        self.title = title
        self.summary = summary
        self.isDestructive = isDestructive
        self.entries = entries
        self.card = card
        self.validation = validation
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.state = .staged
        self.evidence = []
        self.error = nil
    }
}

/// What planning produced for one agent request: the operations approval
/// would run, plus everything the review card shows. Pure data — producing
/// it has no side effects, and staging it is the store's job.
public struct Plan: Sendable, Equatable {
    public let tool: String
    public let title: String
    public let summary: String
    public let isDestructive: Bool
    public let operations: [HomeKitOperation]
    public let entries: [ProposalDiffEntry]
    public let card: [ProposalCardLine]
    public let validation: ProposalValidation

    public init(
        tool: String,
        title: String,
        summary: String,
        isDestructive: Bool,
        operations: [HomeKitOperation],
        entries: [ProposalDiffEntry],
        card: [ProposalCardLine],
        validation: ProposalValidation = .passed
    ) {
        self.tool = tool
        self.title = title
        self.summary = summary
        self.isDestructive = isDestructive
        self.operations = operations
        self.entries = entries
        self.card = card
        self.validation = validation
    }
}
