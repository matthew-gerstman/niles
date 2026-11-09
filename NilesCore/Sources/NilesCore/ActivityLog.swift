import Foundation

/// One entry in the persistent activity timeline: everything that happened
/// to a proposal, in the order it happened. Events are append-only history —
/// they record when things changed, which a state snapshot cannot.
public struct ActivityEvent: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// The agent staged a new proposal.
        case staged
        /// The human decided; `decision` says "approved" or "denied".
        case decided
        /// Execution ran (or failed); `evidence` carries the read-back and
        /// `detail` the outcome (the error, or the confirmed-check count).
        case executed
        /// The proposal expired without a decision; nothing ran.
        case expired
        /// A paired-revert undo executed: the original change had applied and
        /// the revert restored the prior state (`revertsProposalId` links to it).
        case undone
    }

    public let id: String
    public let at: Date
    public let kind: Kind
    public let proposalId: String
    public let proposalTitle: String
    /// The agent that staged the proposal, attributed at arrival.
    public let agentName: String?
    /// For `.decided`: "approved" or "denied".
    public let decision: String?
    /// Human-readable outcome note — the failure text, an undo description.
    public let detail: String?
    /// Read-back evidence, attached on `.executed` in its structured form —
    /// per-check claim/observed/confirmed, not flattened prose.
    public let evidence: [ProposalEvidence]

    public init(
        id: String = UUID().uuidString,
        at: Date,
        kind: Kind,
        proposalId: String,
        proposalTitle: String,
        agentName: String? = nil,
        decision: String? = nil,
        detail: String? = nil,
        evidence: [ProposalEvidence] = []
    ) {
        self.id = id
        self.at = at
        self.kind = kind
        self.proposalId = proposalId
        self.proposalTitle = proposalTitle
        self.agentName = agentName
        self.decision = decision
        self.detail = detail
        self.evidence = evidence
    }
}

/// The append-only audit log behind the Activity tab. Every event is
/// appended in memory and written through to one JSON file, so the timeline
/// survives relaunch. The log records history; proposal state itself stays
/// in-memory (the spec's split).
public actor ActivityLog {
    /// Events are small and decisions are human-paced: one file rewritten per
    /// append stays fast for years of use at this scale, and is far simpler
    /// than any journaling scheme.
    private static let fileName = "activity-log.json"

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    /// Assigned in init (which loads from disk). No default value: under
    /// Swift 6 actor isolation a defaulted property is initialized before
    /// the nonisolated init body runs, and reassigning it there would be an
    /// isolated write from a nonisolated context.
    public private(set) var events: [ActivityEvent]

    /// - Parameter directory: where the log lives. The app passes nil and
    ///   gets Application Support/Niles; tests pass a temp directory.
    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
        // Reload on init: the timeline picks up where the last run left off.
        events = Self.read(from: fileURL, decoder: decoder)
    }

    /// Pure over immutable state (`directory` is a let), so callable from
    /// anywhere — including the nonisolated init, which reads it to reload.
    public nonisolated var fileURL: URL {
        directory.appendingPathComponent(Self.fileName)
    }

    public func append(_ event: ActivityEvent) {
        events.append(event)
        persist()
    }

    public func allEvents() -> [ActivityEvent] {
        events
    }

    /// Write-through persistence. A failure is surfaced but never thrown —
    /// the in-memory timeline stays authoritative for the session, and a
    /// history file must not take a decision down with it.
    private func persist() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(events).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("ActivityLog: persist failed: \(error)")
        }
    }

    /// A missing file is a first launch. A corrupt one degrades to empty —
    /// history is not state the pipeline depends on, so the app launches —
    /// but the corruption is logged, never silent.
    private static func read(from url: URL, decoder: JSONDecoder) -> [ActivityEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        do {
            return try decoder.decode([ActivityEvent].self, from: data)
        } catch {
            NSLog("ActivityLog: could not decode \(url.lastPathComponent), starting empty: \(error)")
            return []
        }
    }

    public static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Niles", isDirectory: true)
    }
}
