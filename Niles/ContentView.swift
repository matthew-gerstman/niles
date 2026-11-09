import SwiftUI
import NilesCore

/// Root tab view: Dashboard, Approvals, Home graph, Pairing — one tab per
/// mockup screen, with a pending-count badge on Approvals. Holds the live
/// store; previews substitute it for the in-memory one behind the same
/// view-model protocols.
struct ContentView: View {
    @State private var store: LiveNilesStore

    enum NilesTab: String, CaseIterable, Identifiable {
        case dashboard, approvals, home, pairing
        var id: String { rawValue }
    }

    @State private var selectedTab: NilesTab = .dashboard

    init(store: LiveNilesStore) {
        _store = State(initialValue: store)
    }

    private var pendingCount: Int { store.pendingProposals.count }

    var body: some View {
        TabView(selection: $selectedTab) {
            DashboardScreen(model: store, onOpenApprovals: { selectedTab = .approvals })
                .tabItem { Label("Dashboard", systemImage: "house") }
                .tag(NilesTab.dashboard)
            ApprovalsScreen(model: store)
                .tabItem { Label("Approvals", systemImage: "checkmark.circle") }
                .badge(pendingCount)
                .tag(NilesTab.approvals)
            HomeGraphScreen(model: store)
                .tabItem { Label("Home", systemImage: "square.grid.3x3") }
                .tag(NilesTab.home)
            PairingScreen(model: store)
                .tabItem { Label("Pairing", systemImage: "qrcode") }
                .tag(NilesTab.pairing)
        }
        .task { store.start() }
    }
}

#Preview {
    ContentView(
        store: LiveNilesStore(
            coordinator: ServerCoordinator(homeKitService: FakeHomeKitService(graph: .demoFixture)),
            notifier: .disabled
        )
    )
}
