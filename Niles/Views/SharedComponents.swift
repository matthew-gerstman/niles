import SwiftUI
import NilesCore

// The proposal review card's Changes rendering: the card's own line order,
// parsed into one compact group per operation. Batch cards open each
// operation with a '— Operation N of M: title —' banner line, so banners —
// including those persisted by earlier releases — become group headers and
// every line beneath one belongs to that operation. All styling is text
// styles and semantic colors on clear backgrounds (Dynamic Type compliant);
// monospace is reserved for value tokens, never sentences.

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
    /// operation with: '— Operation 2 of 4: Set “X” Brightness to 50 —'.
    /// Persisted proposals expire after 24h, but old ones legitimately
    /// still carry this exact string — parse it, never special-case by age.
    static func bannerFields(of text: String) -> (number: Int, count: Int, title: String)? {
        guard text.hasPrefix("— Operation "), text.hasSuffix(" —") else { return nil }
        let inner = text.dropFirst("— Operation ".count).dropLast(" —".count)
        guard let ofRange = inner.range(of: " of "),
              let number = Int(inner[..<ofRange.lowerBound]) else { return nil }
        let rest = inner[ofRange.upperBound...]
        guard let colonRange = rest.range(of: ": "),
              let count = Int(rest[..<colonRange.lowerBound]) else { return nil }
        return (number, count, String(rest[colonRange.upperBound...]))
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

/// The Changes section body: one compact group per operation, in the
/// card's original order.
struct ProposalChangesView: View {
    let lines: [ProposalDiffLine]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(ProposalCardLayout.operationGroups(from: lines)) { group in
                ProposalOperationGroupView(group: group)
            }
        }
    }
}

private struct ProposalOperationGroupView: View {
    let group: ProposalOperationGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = group.title {
                HStack(spacing: 6) {
                    Image(systemName: ProposalCardLayout.symbolName(forOperationTitle: title))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    if let number = group.operationNumber, let count = group.operationCount {
                        Text("\(number) of \(count)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(group.lines) { line in
                changeLine(line)
            }
        }
    }

    @ViewBuilder
    private func changeLine(_ line: ProposalDiffLine) -> some View {
        switch line.kind {
        case .note:
            WarningRow(text: line.text)
        default:
            HStack(alignment: .center, spacing: 8) {
                leadingAccent(for: line.kind)
                ChangeLineText(text: line.text)
                    .font(.callout)
            }
        }
    }

    /// A small leading accent instead of a full-width fill: plus/minus
    /// glyphs for diff lines, a neutral 3pt bar for plain context.
    @ViewBuilder
    private func leadingAccent(for kind: ProposalDiffLine.Kind) -> some View {
        switch kind {
        case .add:
            Text("+")
                .font(.callout.weight(.bold))
                .foregroundStyle(.green)
        case .remove:
            Text("−")
                .font(.callout.weight(.bold))
                .foregroundStyle(.red)
        case .plain, .note:
            Capsule()
                .fill(Color.secondary.opacity(0.35))
                .frame(width: 3, height: 14)
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

/// A blast-radius or validation warning: a compact footnote row with an
/// orange glyph, no background fill. The card text's leading '⚠ ' is
/// dropped — the glyph replaces it.
private struct WarningRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
            Text(Self.warningText(of: text))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    static func warningText(of text: String) -> String {
        text.hasPrefix("⚠ ") ? String(text.dropFirst(2)) : text
    }
}
