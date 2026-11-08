import SwiftUI

/// Root tab view: Dashboard, Approvals, Home graph, Pairing — one tab per
/// mockup screen, with a pending-count badge on Approvals.
struct ContentView: View {
    enum NilesTab: String, CaseIterable, Identifiable {
        case dashboard, approvals, home, pairing
        var id: String { rawValue }
    }

    /// Presentational store for now; the live-wiring task swaps in a real one
    /// behind the same view-model protocols.
    @State private var store = InMemoryNilesStore()
    @State private var selectedTab: NilesTab = .dashboard

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
    }
}

#Preview {
    ContentView()
}
