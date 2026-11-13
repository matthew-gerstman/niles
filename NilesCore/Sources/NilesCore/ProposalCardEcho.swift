import Foundation

/// Echo rules for the proposal review card: which member lines merely
/// restate their operation's header and need not render. Pure predicates
/// over the persisted card strings — serialization is untouched, so old
/// proposals parse exactly like fresh ones. The app's changes view filters
/// with these before rendering (PR #109's succinct pass); they live in
/// NilesCore because they encode what the card format itself guarantees.
public enum ProposalCardEcho {
    /// True when the line merely restates the header: a lead of the form
    /// 'Kind “Name”' that appears verbatim in the title, with a ' · ' tail
    /// whose verb is the title's verb in past tense ('Create scene “X”' /
    /// 'Scene “X” · created with 1 action'). A ' → ' transition line is
    /// never this kind of echo — its right side is information the title
    /// lacks ('Scene “A” → “B”' under 'Rename scene “A”').
    public static func isEcho(_ text: String, ofTitle title: String) -> Bool {
        guard !text.contains(" → ") else { return false }
        guard let tailRange = text.range(of: " · ") else { return false }
        let lead = String(text[..<tailRange.lowerBound])
        // A bare '“Name” · add action …' line is real detail, not a
        // restatement — only a lead carrying a kind word before the
        // quoted name can duplicate a header.
        guard !lead.hasPrefix("“"), title.localizedCaseInsensitiveContains(lead) else { return false }
        let titleVerb = verbPrefix(title)
        let tailVerb = verbPrefix(String(text[tailRange.upperBound...]))
        // 'created'/'Create', 'identified'/'Identify', 'deleted'/'Delete',
        // 'runs'/'Run', 'unblocked'/'Unblock' — a shared word stem.
        return commonPrefixLength(titleVerb, tailVerb) >= 3
    }

    /// True when the line is an accessory move's own detail row —
    /// 'Accessory “X” · “From” → “To”' — under a 'Move accessory “X” to Y'
    /// header. Unlike every other transition line this one is a pure echo:
    /// the header already carries the name and the destination; the source
    /// room is the only new fact, and it carries no decision weight
    /// (Matthew, Nov 13 — the last of PR #109's echo class). Matched on the
    /// persisted strings so old batches render identically. Scene-action,
    /// characteristic-write, and trigger-transition lines keep rendering —
    /// there the ' → ' row IS the payload.
    public static func isMoveEcho(_ text: String, ofTitle title: String) -> Bool {
        guard title.hasPrefix("Move accessory “"), text.hasPrefix("Accessory “") else { return false }
        guard let nameEnd = text.range(of: "”") else { return false }
        // The header quotes the same accessory name: 'Move accessory “X” to …'.
        let quotedName = text[text.index(text.startIndex, offsetBy: "Accessory ".count)..<nameEnd.upperBound]
        return title.contains(quotedName)
    }

    private static func verbPrefix(_ text: String) -> String {
        String(text.prefix(while: { !$0.isWhitespace })).lowercased()
    }

    private static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix(while: { $0.0 == $0.1 }).count
    }
}
