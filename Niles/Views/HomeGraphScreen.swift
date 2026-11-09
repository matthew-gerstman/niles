import SwiftUI

/// Home graph: Rooms, Zones, Scenes and Triggers — exactly what agents see
/// through the read tools. Rows are actionable: swipe right full-swipes the
/// primary action (Run scene, Arm/Disarm trigger, Rename otherwise); swipe
/// left opens quick actions (Run / Rename / Delete, context-appropriate).
/// Every action stages a proposal — nothing applies from this screen.
struct HomeGraphScreen: View {
    var model: any HomeGraphViewModel

    /// The rename prompt's target row; non-nil shows the alert.
    @State private var renameTarget: HomeRow?
    @State private var renameText = ""

    var body: some View {
        ScreenScaffold(title: "Home", subtitle: "Swipe a row to stage a change — nothing runs until you approve it") {
            if model.sections.isEmpty {
                EmptyStateCard(text: "No home graph yet. Connect to HomeKit to see rooms, zones, scenes, and triggers.")
            } else {
                ForEach(model.sections) { section in
                    SectionHeader(title: section.title)
                    sectionCard(section)
                }
            }
        }
        .alert(
            "Rename “\(renameTarget?.name ?? "")”",
            isPresented: Binding(
                get: { renameTarget != nil },
                set: { if !$0 { renameTarget = nil } }
            )
        ) {
            TextField("New name", text: $renameText)
            Button("Stage Rename") {
                if let target = renameTarget { stage(target, .rename, newName: renameText) }
                renameTarget = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The rename is staged for your review — nothing applies until you approve it.")
        }
    }

    private func sectionCard(_ section: HomeSection) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                SwipeableHomeRow(row: row) { action, newName in
                    stage(row, action, newName: newName)
                }
                if index < section.rows.count - 1 {
                    Divider()
                }
            }
        }
        .card()
    }

    /// The single funnel to the store's stage path — gestures and the rename
    /// alert both end here, so nothing on Home can apply directly. Rename
    /// without a name yet opens the prompt instead of staging.
    private func stage(_ row: HomeRow, _ action: HomeRowAction, newName: String? = nil) {
        if action == .rename && newName == nil {
            renameText = row.name
            renameTarget = row
            return
        }
        Task { await model.stage(row: row, action: action, newName: newName) }
    }
}

/// One graph row wrapped in the swipe affordances. Swipe right reveals the
/// primary action; releasing past the threshold stages it (a full swipe).
/// Swipe left reveals the quick-action buttons and snaps open; tapping one
/// stages it and closes. Rows without identity stay inert.
private struct SwipeableHomeRow: View {
    let row: HomeRow
    let onStage: (HomeRowAction, String?) -> Void

    @State private var dragX: CGFloat = 0
    /// True while a rightward drag is in flight, so the primary reveal draws
    /// behind the content instead of the quick actions.
    @State private var isDraggingRight = false

    private let stageThreshold: CGFloat = 90
    private let openThreshold: CGFloat = 48
    private let quickActionWidth: CGFloat = 78

    private var quickActions: [HomeRowAction] { row.quickActions }
    private var openWidth: CGFloat { CGFloat(quickActions.count) * quickActionWidth }

    var body: some View {
        ZStack {
            revealedActions
            HomeRowView(row: row)
                .background(Color(.systemBackground))
                .padding(.leading, max(0, dragX))
                .padding(.trailing, max(0, -dragX))
        }
        .clipped()
        .gesture(drag)
    }

    /// What shows behind the row while swiping or open. The two reveals are
    /// mutually exclusive: a right drag shows the primary, anything else
    /// shows the quick actions sized by the remaining reveal width.
    @ViewBuilder
    private var revealedActions: some View {
        if isDraggingRight || dragX > 0 {
            HStack(spacing: 0) {
                if let action = row.primaryAction {
                    SwipeActionButton(action: action, fillsHeight: true) {
                        stage(action)
                    }
                    .frame(width: max(0, max(0, dragX) - 8))
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if -dragX > 0 {
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    ForEach(quickActions, id: \.self) { action in
                        SwipeActionButton(action: action, fillsHeight: true) {
                            stage(action)
                            close()
                        }
                        .frame(width: quickActionWidth - 6)
                    }
                }
                .frame(width: min(max(0, -dragX), openWidth), alignment: .trailing)
                .clipped()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                isDraggingRight = value.translation.width > 0
                let clamped = min(abs(value.translation.width), 180)
                dragX = value.translation.width > 0 ? clamped : -clamped
            }
            .onEnded { value in
                defer { isDraggingRight = false }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                // A quick flick ends with a small final translation; judge it
                // by where the gesture was heading, not where it stopped.
                let travel = max(value.translation.width, value.predictedEndTranslation.width)
                if travel > 0 {
                    // Full swipe right: stage the primary action immediately.
                    if travel > stageThreshold, let action = row.primaryAction {
                        stage(action)
                    }
                    close()
                } else if -travel > openThreshold {
                    withAnimation(.spring(duration: 0.25)) { dragX = -openWidth }
                } else {
                    close()
                }
            }
    }

    private func stage(_ action: HomeRowAction) {
        onStage(action, nil)
    }

    private func close() {
        withAnimation(.spring(duration: 0.25)) { dragX = 0 }
    }
}

/// One swipe-revealed button. Delete is the only red action — the red accent
/// stays reserved for destructive choices (spec: severity tokens).
private struct SwipeActionButton: View {
    let action: HomeRowAction
    let fillsHeight: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 3) {
                Image(systemName: action.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                Text(action.title)
                    .font(.system(size: 11, weight: .bold))
            }
            .frame(maxWidth: .infinity, maxHeight: fillsHeight ? .infinity : nil)
            .background(background)
            .foregroundStyle(foreground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var background: Color {
        switch action {
        case .delete: NilesTheme.destructive.opacity(0.14)
        case .run, .setArmed: NilesTheme.accent.opacity(0.12)
        case .rename: Color.primary.opacity(0.06)
        }
    }

    private var foreground: Color {
        switch action {
        case .delete: NilesTheme.destructive
        case .run, .setArmed: NilesTheme.accent
        case .rename: .primary
        }
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
