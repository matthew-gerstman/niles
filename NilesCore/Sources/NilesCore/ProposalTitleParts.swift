/// Pure split of a proposal title into its action headline and the quoted
/// entity it acts on (Activity row, 2026-11-14): `Rename “Kitchen” to
/// “Cookery”` renders as a two-line row — `Rename` as the headline, `Kitchen`
/// as the secondary second line. Titles without a `“…”` quoted span (`Move
/// Office into Upstairs`, an `Undo — …` line naming no entity) keep their
/// one-line treatment.
public enum ProposalTitleParts {
    /// The action before the quote and the entity inside it.
    public struct Parts: Equatable {
        /// Text before the opening quote, trimmed — the row's headline.
        public let action: String
        /// Text inside the first `“…”` span — the row's second line.
        public let entity: String
    }

    /// Splits on the title's first `“…”` quoted span. Nil when there is no
    /// quote (or no action before it) — the caller keeps the title as one line.
    public static func split(_ title: String) -> Parts? {
        guard let open = title.firstIndex(of: "“") else { return nil }
        guard let close = title[title.index(after: open)...].firstIndex(of: "”") else { return nil }
        let action = String(title[..<open]).trimmingCharacters(in: .whitespaces)
        guard !action.isEmpty else { return nil }
        return Parts(action: action, entity: String(title[title.index(after: open)..<close]))
    }
}
