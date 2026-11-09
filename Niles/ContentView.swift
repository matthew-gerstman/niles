import SwiftUI
import NilesCore

/// Root tab view: Queue, Activity, Home, Settings — matching the approved
/// queue-first mockup, with a pending-count badge on Queue. Activity and
/// Settings are placeholder stubs until later PRs in the rebuild; the
/// Dashboard and Pairing screens remain in the tree for that work. Holds the
/// live store; previews substitute it for the in-memory one behind the same
/// view-model protocols.
struct ContentView: View {
    @State private var store: LiveNilesStore

    enum NilesTab: String, CaseIterable, Identifiable {
        case queue, activity, home, settings
        var id: String { rawValue }
    }

    @State private var selectedTab: NilesTab = {
    // Test/screenshot hook: `simctl launch ... -UITabSelect activity` opens a
    // given tab so per-tab captures don't need UI automation.
    if let arg = ProcessInfo.processInfo.arguments.firstMatch(of: /-UITabSelect (\w+)/) {
        return NilesTab(rawValue: String(arg.1)) ?? .queue
    }
    return .queue
}()

    init(store: LiveNilesStore) {
        _store = State(initialValue: store)
    }

    private var pendingCount: Int { store.pendingProposals.count }

    var body: some View {
        TabView(selection: $selectedTab) {
            ApprovalsScreen(model: store)
                .tabItem { Label("Queue", systemImage: "list.bullet.rectangle") }
                .badge(pendingCount)
                .tag(NilesTab.queue)
            ActivityScreenPlaceholder(model: store)
                .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
                .tag(NilesTab.activity)
            HomeGraphScreen(model: store)
                .tabItem { Label("Home", systemImage: "square.grid.3x3") }
                .tag(NilesTab.home)
            SettingsScreenPlaceholder(model: store)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(NilesTab.settings)
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
