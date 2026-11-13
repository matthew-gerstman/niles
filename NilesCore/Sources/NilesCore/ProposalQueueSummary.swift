import Foundation

/// The batch card's banner format, owned here next to the code that
/// produces it (`ProposalStoreBatching.merge()` writes
/// '— Operation 2 of 4: Set "X" Brightness to 50 —' as the first line of
/// every batch operation). Persisted proposals expire after 24h, but old
/// ones legitimately still carry this exact string — parse it, never
/// special-case by age.
public enum ProposalCardBanner {
    /// Parses a banner line into its 1-based operation number, batch size,
    /// and the member operation's title. Nil for any non-banner line.
    public static func fields(of text: String) -> (number: Int, count: Int, title: String)? {
        guard text.hasPrefix("— Operation "), text.hasSuffix(" —") else { return nil }
        let inner = text.dropFirst("— Operation ".count).dropLast(" —".count)
        guard let ofRange = inner.range(of: " of "),
              let number = Int(inner[..<ofRange.lowerBound]) else { return nil }
        let rest = inner[ofRange.upperBound...]
        guard let colonRange = rest.range(of: ": "),
              let count = Int(rest[..<colonRange.lowerBound]) else { return nil }
        return (number, count, String(rest[colonRange.upperBound...]))
    }
}

/// Pure derivation of the queue row's per-operation bullet lines (Matthew,
/// 2026-11-13): a batch queue row lists each member operation as its own
/// one-line bullet — the same succinct titles the detail card groups on —
/// instead of one truncated first-line summary. Long batches stay compact:
/// beyond the cap the row renders one '+N more' overflow line.
public enum ProposalQueueSummary {
    /// The bullets a queue row renders for a card's lines.
    public struct Bullets: Equatable {
        /// One line per operation, at most `cap` entries.
        public let lines: [String]
        /// Operations beyond the cap — render as '+N more'. Zero when every
        /// operation has its own bullet.
        public let overflowCount: Int
    }

    /// One bullet per batch operation (banner titles, in card order), capped.
    /// A card with no banners (a single-op proposal, or a legacy batch) yields
    /// no bullets — the row keeps its previous summary treatment.
    public static func bullets(from lines: [String], cap: Int = defaultCap) -> Bullets {
        let titles = lines.compactMap { ProposalCardBanner.fields(of: $0)?.title }
        guard titles.count > cap else { return Bullets(lines: titles, overflowCount: 0) }
        return Bullets(lines: Array(titles.prefix(cap)), overflowCount: titles.count - cap)
    }

    /// A cap of 4 keeps an 18-op batch (and its Destructive/metadata
    /// captions) inside roughly one row height while still showing the
    /// batch's shape.
    public static let defaultCap = 4
}
