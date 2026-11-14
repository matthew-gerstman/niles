import SwiftUI
import NilesCore

// The proposal review card's Changes rendering: the card's own line order,
// parsed into one succinct group per operation. Batch cards open each
// operation with a '— Operation N of M: title —' banner line, so banners —
// including those persisted by earlier releases — become group headers and
// every line beneath one belongs to that operation. The header is the
// operation: member lines survive only when they add detail the title does
// not already say. All styling is text styles and semantic colors on clear
// backgrounds (Dynamic Type compliant); monospace is reserved for value
// tokens, never sentences.

/// One operation group of a proposal's changes: the parsed banner header
/// (nil for a single-op card, which has no banner) and the lines beneath it.
struct ProposalOperationGroup: Identifiable {
    /// Position in the card, for stable identity in ForEach.
    let id: Int
    /// 1-based operation number and batch size, parsed from the banner.
    let operationNumber: Int?
    let operationCount: Int?
    /// The member operation's title, from the banner.
    let title: String?
    var lines: [ProposalDiffLine]
}

/// Pure parsing/derivation for the changes card, split from the views so
/// the rules are directly inspectable (the app target ships without tests
/// by policy, so clarity carries the weight tests otherwise would).
enum ProposalCardLayout {
    /// Splits a card's lines into operation groups. A banner line opens a
    /// new group; lines before any banner form a single unheadered group
    /// (the single-op shape).
    static func operationGroups(from lines: [ProposalDiffLine]) -> [ProposalOperationGroup] {
        var groups: [ProposalOperationGroup] = []
        for line in lines {
            if let banner = bannerFields(of: line.text) {
                groups.append(ProposalOperationGroup(
                    id: groups.count,
                    operationNumber: banner.number,
                    operationCount: banner.count,
                    title: banner.title,
                    lines: []
                ))
            } else if groups.isEmpty {
                groups.append(ProposalOperationGroup(
                    id: 0, operationNumber: nil, operationCount: nil, title: nil, lines: [line]
                ))
            } else {
                groups[groups.count - 1].lines.append(line)
            }
        }
        return groups
    }

    /// The banner line `ProposalStoreBatching.merge()` opens every batch
    /// operation with — parsed in NilesCore (`ProposalCardBanner`), next to
    /// the code that produces the format.
    static func bannerFields(of text: String) -> (number: Int, count: Int, title: String)? {
        ProposalCardBanner.fields(of: text)
    }

    /// SF Symbol for a member operation, inferred from its title's leading
    /// verb — the card carries titles, not tool names, and old persisted
    /// batches only ever will.
    static func symbolName(forOperationTitle title: String) -> String {
        if title.hasPrefix("Identify") { return "light.beacon.max" }
        if title.hasPrefix("Rename") { return "pencil" }
        if title.hasPrefix("Delete") { return "trash" }
        if title.hasPrefix("Set ") { return "dial.max" }
        if title.contains("scene") { return "rectangle.stack" }
        if title.contains("room") { return "table.furniture" }
        if title.contains("zone") { return "square.on.square" }
        if title.contains("group") { return "rectangle.3.group" }
        if title.contains("trigger") { return "timer" }
        return "wrench.and.screwdriver"
    }

    /// Semantic tint for a member operation's header symbol — the single
    /// source of truth for icon color (pass 3). Matching order mirrors
    /// symbolName's verb-first rules so symbol and tint never disagree.
    /// System colors only, consistent with the Activity verdict tints and
    /// PR #110's swipe colors (approve green, deny red, undo orange):
    /// scene ops green, characteristic writes (device-immediate) orange,
    /// identify blue, delete red, rename mint, zone indigo, room teal,
    /// service-group cyan, trigger purple.
    static func tint(forOperationTitle title: String) -> Color {
        if title.hasPrefix("Identify") { return .blue }
        if title.hasPrefix("Rename") { return .mint }
        if title.hasPrefix("Delete") { return .red }
        if title.hasPrefix("Set ") { return .orange }
        if title.contains("scene") { return .green }
        if title.contains("room") { return .teal }
        if title.contains("zone") { return .indigo }
        if title.contains("group") { return .cyan }
        if title.contains("trigger") { return .purple }
        return .secondary
    }

    // MARK: - Succinct filtering (review pass 2)

    /// The succinct card's per-group filter: the header already says what
    /// the operation does, so a member line survives only when it adds
    /// detail the title does not carry. Runs purely on the persisted card
    /// text — serialization is untouched — so old proposals render
    /// identically to fresh ones.
    static func succinctLines(title: String?, lines: [ProposalDiffLine]) -> [ProposalDiffLine] {
        lines.compactMap { line in succinctLine(line, title: title) }
    }

    private static func succinctLine(_ line: ProposalDiffLine, title: String?) -> ProposalDiffLine? {
        switch line.kind {
        case .note:
            return noteLine(line.text)
        default:
            // Echo rows only exist under a header — a single-op card has
            // no title to restate, so its lines all stand on their own.
            // The accessory-move detail row is a ' → ' transition, the one
            // shape isEcho never drops; its own predicate finishes the
            // echo class for moves.
            guard let title else { return line }
            if ProposalCardEcho.isMoveEcho(line.text, ofTitle: title)
                || ProposalCardEcho.isEcho(line.text, ofTitle: title) { return nil }
            return line
        }
    }

    /// A ⚠ note either carries a blast-radius fact the spec requires the
    /// user to see — demoted to a plain detail line, no glyph — or it is
    /// agent-facing slop and disappears entirely.
    private static func noteLine(_ text: String) -> ProposalDiffLine? {
        guard text.hasPrefix("⚠ ") else {
            // Notes without the warning prefix (the revert card's
            // 'Reverts “X” — …') are context, not warnings.
            return ProposalDiffLine(.plain, text)
        }
        let stripped = String(text.dropFirst("⚠ ".count))
        guard isBlastRadiusNote(stripped) else { return nil }
        return ProposalDiffLine(.plain, firstSentence(stripped))
    }

    /// The ⚠ classes that survive as plain detail: destructive-reference
    /// facts — what else this operation touches, not how the agent should
    /// call it. Device-immediacy is deliberately absent (pass 3): the
    /// change row's current → target values already say it, and the prose
    /// footnote added nothing.
    static func isBlastRadiusNote(_ text: String) -> Bool {
        text.contains(" will move to the default room")
            || text.contains(" no longer runs anything")
            || text.contains(" loses ")
            || text.contains("will stop working")
            || text.contains("armed state")
    }

    /// Drops an agent-facing tail sentence ('Pass deleteLinkedTriggers to
    /// delete it too.') — the user-facing first sentence is the detail.
    static func firstSentence(_ text: String) -> String {
        guard let range = text.range(of: ". ") else { return text }
        return String(text[..<range.lowerBound]) + "."
    }

    /// The echo predicates live in NilesCore (`ProposalCardEcho`) — they
    /// encode what the persisted card format guarantees and are unit-tested
    /// there; this filter only applies them.

    /// One run of styled text inside a change line.
    struct ChangeTextSegment {
        enum Style { case primary, secondary, semibold }
        let text: String
        let style: Style
    }

    /// Splits a change line around its value transition: '… Brightness
    /// 73 → 50' renders '73' secondary and '50' semibold. Renames ('Scene
    /// “A” → “B”') qualify too — the old value is the left side's last
    /// quoted token. A left token only reads as the old value when it is a
    /// value token (numeric or quoted), so 'Power State → 1' keeps its
    /// whole left side primary.
    static func transitionSegments(of text: String) -> [ChangeTextSegment] {
        guard let arrow = text.range(of: " → ", options: .backwards) else {
            return [ChangeTextSegment(text: text, style: .primary)]
        }
        let left = String(text[..<arrow.lowerBound])
        let right = String(text[arrow.upperBound...])
        if let lastSpace = left.lastIndex(of: " ") {
            let oldValue = String(left[left.index(after: lastSpace)...])
            if isValueToken(oldValue) {
                let prefix = String(left[..<left.index(after: lastSpace)])
                return [
                    ChangeTextSegment(text: prefix, style: .primary),
                    ChangeTextSegment(text: oldValue, style: .secondary),
                    ChangeTextSegment(text: " → ", style: .secondary),
                    ChangeTextSegment(text: right, style: .semibold),
                ]
            }
        }
        return [
            ChangeTextSegment(text: left, style: .primary),
            ChangeTextSegment(text: " → ", style: .secondary),
            ChangeTextSegment(text: right, style: .semibold),
        ]
    }

    private static func isValueToken(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        if token.allSatisfy(\.isNumber) { return true }
        return token.hasPrefix("“") && token.hasSuffix("”")
    }
}

/// The Changes section body: one succinct group per operation, in the
/// card's original order. Each group renders its header plus only the
/// detail the header does not already say.
struct ProposalChangesView: View {
    let lines: [ProposalDiffLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(ProposalCardLayout.operationGroups(from: lines)) { group in
                ProposalOperationGroupView(group: succinct(group))
            }
        }
    }

    private func succinct(_ group: ProposalOperationGroup) -> ProposalOperationGroup {
        var group = group
        group.lines = ProposalCardLayout.succinctLines(title: group.title, lines: group.lines)
        return group
    }
}

private struct ProposalOperationGroupView: View {
    let group: ProposalOperationGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = group.title {
                header(title)
                // Detail nests under the header text: an invisible copy of
                // the header's own symbol reserves exactly the icon column
                // (spacing included), at any Dynamic Type size — the same
                // rule for every line, no hard-coded inset.
                ForEach(group.lines) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: ProposalCardLayout.symbolName(forOperationTitle: title))
                            .font(.subheadline)
                            .hidden()
                        detailLine(line)
                    }
                }
            } else {
                ForEach(group.lines) { line in
                    detailLine(line)
                }
            }
        }
    }

    private func header(_ title: String) -> some View {
        // First-baseline alignment: a wrapped title keeps the "N of M"
        // caption on the first line instead of centering against the block.
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: ProposalCardLayout.symbolName(forOperationTitle: title))
                .font(.subheadline)
                .foregroundStyle(ProposalCardLayout.tint(forOperationTitle: title))
            Text(title)
                .font(.subheadline.weight(.semibold))
            // The caption keeps its natural fixed width at the trailing
            // edge; the title gets everything else and wraps when the two
            // collide at narrow widths (folded Duo, user report Nov 14).
            Spacer(minLength: 8)
            if let number = group.operationNumber, let count = group.operationCount {
                Text("\(number) of \(count)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }

    /// The lines under a header: the change itself (any value transition
    /// keeps PR #108's old-secondary/new-semibold styling) or a supporting
    /// detail in the secondary color. No leading glyphs — the header is
    /// the operation; pluses and minuses added nothing the colors of a
    /// review card needed.
    @ViewBuilder
    private func detailLine(_ line: ProposalDiffLine) -> some View {
        switch line.kind {
        case .add, .remove:
            ChangeLineText(text: line.text)
                .font(.callout)
        case .plain, .note:
            if line.text.contains(" → ") {
                ChangeLineText(text: line.text)
                    .font(.callout)
            } else {
                Text(line.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// A change line in the system face, with any value transition styled:
/// the old value secondary, the new value semibold. Text concatenation
/// keeps every segment on one Dynamic Type line.
private struct ChangeLineText: View {
    let text: String

    var body: some View {
        ProposalCardLayout.transitionSegments(of: text).reduce(Text("")) { result, segment in
            result + styled(segment)
        }
    }

    private func styled(_ segment: ProposalCardLayout.ChangeTextSegment) -> Text {
        switch segment.style {
        case .primary: Text(segment.text)
        case .secondary: Text(segment.text).foregroundStyle(.secondary)
        case .semibold: Text(segment.text).fontWeight(.semibold)
        }
    }
}
