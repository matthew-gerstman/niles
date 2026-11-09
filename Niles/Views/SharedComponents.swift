import SwiftUI

/// Semantic design tokens from the approved mockup, resolved from the asset
/// catalog (`Assets.xcassets`) so light and dark variants are correct by
/// construction. Accent is Grappa #544556; red is reserved strictly for
/// destructive actions and denials.
enum NilesTheme {
    static let accent = Color("accent")
    static let destructive = Color("destructive")
    static let good = Color("good")
    static let warn = Color("warn")
}

// MARK: - Card and scaffold

/// White rounded card with the mockup's soft shadow; `accent` draws the
/// 4pt left edge (accent for proposals, red for destructive ones).
private struct CardStyle: ViewModifier {
    var accent: Color?

    func body(content: Content) -> some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .leading) {
                if let accent {
                    UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14)
                        .fill(accent)
                        .frame(width: 4)
                }
            }
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
    }
}

extension View {
    func card(accent: Color? = nil) -> some View {
        modifier(CardStyle(accent: accent))
    }
}

/// Uppercase section heading ("PENDING APPROVAL").
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .bold))
            .tracking(0.6)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.top, 22)
            .padding(.bottom, 8)
            .padding(.leading, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Big title + subtitle header every mockup screen shares.
struct ScreenScaffold<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 30, weight: .heavy))
                    .tracking(-0.5)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    .padding(.bottom, 4)
                content()
                    .padding(.bottom, 20)
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(.systemGroupedBackground))
    }
}

// MARK: - Buttons and chips

/// The mockup's three button styles: filled accent, gray ghost, red danger.
struct ActionButton: View {
    enum Style { case primary, ghost, danger }

    let title: String
    let style: Style
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(background)
                .foregroundStyle(foreground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .opacity(isEnabled ? 1 : 0.5)
        }
    }

    private var background: Color {
        switch style {
        case .primary: NilesTheme.accent
        case .ghost: Color.primary.opacity(0.06)
        case .danger: NilesTheme.destructive.opacity(0.1)
        }
    }

    private var foreground: Color {
        switch style {
        case .primary: .white
        case .ghost: .primary
        case .danger: NilesTheme.destructive
        }
    }
}

/// Monospaced "set_zone_rooms · prop_8f2a" chip.
struct ToolChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.05))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// The green/red/amber/neutral diff block on proposal cards and sheets.
struct DiffLineList: View {
    let lines: [ProposalDiffLine]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(lines) { line in
                Text(line.text)
                    .font(font(for: line.kind))
                    .foregroundStyle(foreground(for: line.kind))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(background(for: line.kind))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.1)))
    }

    private func background(for kind: ProposalDiffLine.Kind) -> Color {
        switch kind {
        case .add: NilesTheme.good.opacity(0.14)
        case .remove: NilesTheme.destructive.opacity(0.12)
        case .note: NilesTheme.warn.opacity(0.14)
        case .plain: Color.primary.opacity(0.03)
        }
    }

    private func foreground(for kind: ProposalDiffLine.Kind) -> Color {
        switch kind {
        case .add: NilesTheme.good
        case .remove: NilesTheme.destructive
        case .note: NilesTheme.warn
        case .plain: .primary
        }
    }

    private func font(for kind: ProposalDiffLine.Kind) -> Font {
        switch kind {
        case .note: .system(size: 12)
        case .plain, .add, .remove: .system(size: 12, design: .monospaced)
        }
    }
}

// MARK: - Rows

/// Avatar + name + detail + Active/Idle pill, shared by agent lists.
struct AgentRow: View {
    let agent: AgentConnection

    var body: some View {
        HStack(spacing: 12) {
            Text(String(agent.name.first ?? "?"))
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(Circle().fill(NilesTheme.accent))
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name)
                    .font(.system(size: 15, weight: .semibold))
                Text(agent.detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusPill(isActive: agent.isActive)
        }
        .padding(.vertical, 10)
    }
}

private struct StatusPill: View {
    let isActive: Bool

    var body: some View {
        Text(isActive ? "Active" : "Idle")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(isActive ? NilesTheme.good : Color.primary.opacity(0.45))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(isActive ? NilesTheme.good.opacity(0.12) : Color.primary.opacity(0.06))
            .clipShape(Capsule())
    }
}

/// `key … value` lines with hairline dividers, like the mockup's `.kv` rows.
struct KeyValueList: View {
    let rows: [KeyValueRow]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                HStack {
                    Text(row.key)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(row.value)
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                        .multilineTextAlignment(.trailing)
                }
                .padding(.vertical, 6)
                if index < rows.count - 1 {
                    Divider()
                }
            }
        }
    }
}
