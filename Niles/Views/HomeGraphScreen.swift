import SwiftUI

/// Read-only home graph: Rooms, Zones, Scenes and Triggers, exactly what
/// agents see through the read tools.
struct HomeGraphScreen: View {
    var model: any HomeGraphViewModel

    var body: some View {
        ScreenScaffold(title: "Home", subtitle: "Read-only — what agents see") {
            if model.sections.isEmpty {
                EmptyStateCard(text: "No home graph yet. Connect to HomeKit to see rooms, zones, scenes, and triggers.")
            } else {
                ForEach(model.sections) { section in
                    SectionHeader(title: section.title)
                    sectionCard(section)
                }
            }
        }
    }

    private func sectionCard(_ section: HomeSection) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                HomeRowView(row: row)
                if index < section.rows.count - 1 {
                    Divider()
                }
            }
        }
        .card()
    }
}

/// One graph row: glyph tile, name + subtitle, then either the member count
/// or the OFF tag for disabled rows (the disabled trigger grays out).
private struct HomeRowView: View {
    let row: HomeRow

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(NilesTheme.accent)
                .frame(width: 32, height: 32)
                .background(NilesTheme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(row.isEnabled ? .primary : Color.primary.opacity(0.4))
                Text(row.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !row.isEnabled {
                Text("OFF")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            } else if let count = row.trailingCount {
                Text("\(count)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 10)
    }
}

#Preview("Home graph") {
    HomeGraphScreen(model: InMemoryNilesStore())
}
