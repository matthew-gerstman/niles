import SwiftUI
import NilesCore

/// The app's one deliberate nonstandard view: a diff block with genuine
/// add/remove/note coloring, rendered on system fills and semantic system
/// colors. Fonts are text styles (Dynamic Type compliant); monospace marks
/// diff lines, never sentences.
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
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    private func background(for kind: ProposalDiffLine.Kind) -> Color {
        switch kind {
        case .add: Color.green.opacity(0.14)
        case .remove: Color.red.opacity(0.12)
        case .note: Color.orange.opacity(0.14)
        case .plain: Color(.secondarySystemBackground)
        }
    }

    private func foreground(for kind: ProposalDiffLine.Kind) -> Color {
        switch kind {
        case .add: .green
        case .remove: .red
        case .note: .orange
        case .plain: .primary
        }
    }

    /// Diff lines are identifiers, not sentences — monospace is allowed.
    /// Notes are prose and stay in the system text face.
    private func font(for kind: ProposalDiffLine.Kind) -> Font {
        switch kind {
        case .note: .footnote
        case .plain, .add, .remove: .footnote.monospaced()
        }
    }
}
