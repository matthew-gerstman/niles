import SwiftUI

/// Home graph: Rooms, Zones, Scenes and Triggers — exactly what agents see
/// through the read tools. A native List: rows push a detail, and quick
/// actions live in the row's trailing menu (mirrored in the context menu).
/// Every action stages a proposal — nothing applies from this screen.
struct HomeGraphScreen: View {
    var model: any HomeGraphViewModel

    /// The rename prompt's target row; non-nil shows the alert.
    @State private var renameTarget: HomeRow?
    @State private var renameText = ""
    /// The row pending a delete-stage confirmation; non-nil shows the dialog.
    @State private var deleteTarget: HomeRow?

    var body: some View {
        NavigationStack {
            Group {
                if model.sections.isEmpty {
                    ContentUnavailableView(
                        "No home graph yet",
                        systemImage: "house",
                        description: Text("Connect to HomeKit to see rooms, zones, scenes, and triggers.")
                    )
                } else {
                    List {
                        ForEach(model.sections) { section in
                            Section(section.title) {
                                ForEach(section.rows) { row in
                                    rowView(row)
                                }
                            }
                        }
                        Section {
                            Text("Actions here stage proposals — nothing runs until you approve them in the Queue.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Home")
        }
        .tint(NilesTheme.accent)
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
        .confirmationDialog(
            "Delete “\(deleteTarget?.name ?? "")”?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Stage Delete Proposal", role: .destructive) {
                if let target = deleteTarget {
                    Task { await model.stage(row: target, action: .delete, newName: nil) }
                }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This adds a delete proposal to the Queue for your review — nothing is removed until you approve it.")
        }
    }

    /// Actionable rows push their detail and carry quick actions; rows
    /// without identity stay inert.
    @ViewBuilder
    private func rowView(_ row: HomeRow) -> some View {
        if row.isActionable {
            NavigationLink {
                HomeRowDetail(row: row, onStage: { stage(row, $0) })
            } label: {
                HomeRowCell(row: row, quickActions: row.quickActions) { stage(row, $0) }
            }
            .contextMenu { quickActionButtons(for: row) }
        } else {
            HomeRowCell(row: row) { _ in }
        }
    }

    /// The menu and context menu share these items.
    @ViewBuilder
    private func quickActionButtons(for row: HomeRow) -> some View {
        ForEach(row.quickActions, id: \.self) { action in
            Button(role: action.buttonRole) {
                stage(row, action)
            } label: {
                Label(action.title, systemImage: action.systemImage)
            }
        }
    }

    /// The single funnel to the store's stage path — menus, context menus,
    /// the detail page, and the rename alert all end here, so nothing on
    /// Home can apply directly. Rename without a name yet opens the prompt
    /// instead of staging; delete confirms before staging.
    private func stage(_ row: HomeRow, _ action: HomeRowAction, newName: String? = nil) {
        if action == .rename && newName == nil {
            renameText = row.name
            renameTarget = row
            return
        }
        if action == .delete {
            deleteTarget = row
            return
        }
        Task { await model.stage(row: row, action: action, newName: newName) }
    }
}

/// One graph row: glyph, name + subtitle, then either the member count or
/// the Off tag for disabled rows, and the trailing quick-action menu.
private struct HomeRowCell: View {
    let row: HomeRow
    /// Empty on non-actionable rows: no menu is drawn.
    var quickActions: [HomeRowAction] = []
    let onStage: (HomeRowAction) -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: row.systemImage)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.body)
                    .foregroundStyle(row.isEnabled ? .primary : .secondary)
                Text(row.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !row.isEnabled {
                Text("Off")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else if let count = row.trailingCount {
                Text("\(count)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if !quickActions.isEmpty {
                Menu {
                    ForEach(quickActions, id: \.self) { action in
                        Button(role: action.buttonRole) {
                            onStage(action)
                        } label: {
                            Label(action.title, systemImage: action.systemImage)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.tint)
                }
                .accessibilityLabel("Actions for \(row.name)")
            }
        }
        .padding(.vertical, 2)
    }
}

/// Pushed detail for one graph row: the summary the read tools return, plus
/// the same quick actions. Staging routes back through the screen's funnel.
private struct HomeRowDetail: View {
    let row: HomeRow
    let onStage: (HomeRowAction) -> Void

    var body: some View {
        List {
            Section("Summary") {
                LabeledContent("Type", value: row.kind.map(kindName) ?? "—")
                LabeledContent("Status", value: row.isEnabled ? "Enabled" : "Disabled")
                if let count = row.trailingCount {
                    LabeledContent(countLabel, value: "\(count)")
                }
                LabeledContent("Detail", value: row.subtitle)
            }
            if !row.quickActions.isEmpty {
                Section("Actions") {
                    ForEach(row.quickActions, id: \.self) { action in
                        Button(role: action.buttonRole) {
                            onStage(action)
                        } label: {
                            Label(action.title, systemImage: action.systemImage)
                        }
                    }
                }
            }
        }
        .navigationTitle(row.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func kindName(_ kind: HomeRowKind) -> String {
        switch kind {
        case .room: return "Room"
        case .zone: return "Zone"
        case .scene: return "Scene"
        case .trigger: return "Trigger"
        }
    }

    /// What the row's trailing count counts, by kind.
    private var countLabel: String {
        switch row.kind {
        case .room: return "Accessories"
        case .zone: return "Rooms"
        case .scene: return "Actions"
        case .trigger: return "Count"
        case nil: return "Count"
        }
    }
}

extension HomeRowAction {
    /// Delete is the only destructive action — red comes from the role, not
    /// a custom color (spec: severity rides iOS conventions).
    var buttonRole: ButtonRole? {
        self == .delete ? .destructive : nil
    }
}

#Preview("Home graph") {
    HomeGraphScreen(model: InMemoryNilesStore())
}
