import Foundation

/// The on-disk shape of the proposal store: every proposal (staged and
/// decided), the execution detail behind staged ones, and the paired revert
/// plans of executed ones. Per-proposal activity history lives separately in
/// the activity log (`ActivityLog`), which the app layer writes through —
/// this file is what the pipeline itself needs to resume.
public struct ProposalPersistedState: Codable, Sendable, Equatable {
    public var proposals: [Proposal] = []
    /// Operations behind each staged proposal — what approval would run.
    /// Staged-only by construction: the store clears an entry the moment a
    /// proposal reaches a terminal state.
    public var operations: [String: [HomeKitOperation]] = [:]
    /// Paired reverts captured at execution time, keyed by proposal id —
    /// what keeps Undo alive across a relaunch.
    public var revertPlans: [String: RevertPlan] = [:]
}

/// The proposal store's JSON file in Application Support. The store loads at
/// init and rewrites the whole file on every mutation batch — encoded to a
/// temp file, then renamed over the destination (`Data`'s `.atomic`) — so a
/// crash mid-write can never leave a half file behind.
public struct ProposalStoreFile: Sendable {
    private static let fileName = "proposal-store.json"

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// - Parameter directory: where the file lives. The app passes nil and
    ///   gets Application Support/Niles — the same directory as the activity
    ///   log; tests and fixtures pass a temp directory.
    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
    }

    /// Pure over immutable state (`directory` is a let), so callable from
    /// anywhere — including `ProposalStore`'s nonisolated init.
    public var fileURL: URL {
        directory.appendingPathComponent(Self.fileName)
    }

    public static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Niles", isDirectory: true)
    }

    /// A missing file is a first launch. A corrupt one degrades to empty —
    /// proposal state is recoverable (an agent re-stages), and the
    /// corruption is logged, never silent.
    public func load() -> ProposalPersistedState {
        guard let data = try? Data(contentsOf: fileURL) else { return ProposalPersistedState() }
        do {
            return try decoder.decode(ProposalPersistedState.self, from: data)
        } catch {
            NSLog("ProposalStoreFile: could not decode \(fileURL.lastPathComponent), starting empty: \(error)")
            return ProposalPersistedState()
        }
    }

    /// Write-through persistence. A failure is surfaced but never thrown —
    /// the in-memory store stays authoritative for the session, and a
    /// persistence problem must not take a decision down with it.
    public func persist(_ state: ProposalPersistedState) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(state).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("ProposalStoreFile: persist failed: \(error)")
        }
    }
}
