import SwiftUI
import NilesCore

/// Root tab view: Home, Activity, Niles — matching the approved three-tab
/// mockup. Home carries the Queue (plus the former Settings sections) and
/// the pending-count badge; Niles is the agent chat as a first-class tab.
/// Holds the live store; previews substitute the in-memory one behind the
/// same protocols.
struct ContentView: View {
    @State private var store: LiveNilesStore
    @State private var navigation = AppNavigation.shared
    /// Screenshot/preview hook: `-UIActivityFixtures` renders the Activity tab
    /// on the fixture store instead of the live one, so a fresh simulator has
    /// a populated timeline to capture.
    @State private var fixtureActivityStore: FixtureActivityStore? = {
        if ProcessInfo.processInfo.arguments.contains("-UIActivityFixtures") {
            return FixtureActivityStore()
        }
        return nil
    }()

    enum NilesTab: String, CaseIterable, Identifiable {
        case home, activity, niles
        var id: String { rawValue }
    }

    @State private var selectedTab: NilesTab = {
    // Test/screenshot hook: `simctl launch ... -UITabSelect niles` opens a
    // given tab so per-tab captures don't need UI automation.
    let args = ProcessInfo.processInfo.arguments
    if let i = args.firstIndex(of: "-UITabSelect"), i + 1 < args.count {
        return NilesTab(rawValue: args[i + 1]) ?? .home
    }
    // Deep link from OpenQueueIntent: a cold launch lands on Home, whose
    // Queue section holds the staged proposals awaiting approval. The
    // scroll-to-Queue signal is left for HomeScreen to consume on appear.
    if AppNavigation.shared.queueSelectionPending {
        AppNavigation.shared.consumeQueueSelection()
    }
    return .home
}()

    init(store: LiveNilesStore) {
        _store = State(initialValue: store)
    }

    private var pendingCount: Int { store.pendingProposals.count }

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeScreen(model: store)
                .tabItem { Label("Home", systemImage: "house") }
                .badge(pendingCount)
                .tag(NilesTab.home)
            if let fixture = fixtureActivityStore {
                ActivityScreen(model: fixture)
                    .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
                    .tag(NilesTab.activity)
            } else {
                ActivityScreen(model: store)
                    .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
                    .tag(NilesTab.activity)
            }
            NavigationStack {
                AgentChatScreen(model: store)
            }
            .tabItem { Label("Niles", systemImage: "sparkles") }
            .tag(NilesTab.niles)
        }
        .task {
            store.start()
            await store.seedQueueFixtureIfRequested()
        }
        // Deep link from OpenQueueIntent while the app is already running.
        .onChange(of: navigation.queueSelectionPending) { _, pending in
            guard pending else { return }
            selectedTab = .home
            navigation.consumeQueueSelection()
        }
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
