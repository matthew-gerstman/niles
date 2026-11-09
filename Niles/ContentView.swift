import SwiftUI
import NilesCore

/// Root tab view: Queue, Activity, Home, Settings — matching the approved
/// queue-first mockup, with a pending-count badge on Queue. Settings holds
/// the former Dashboard server card and pairing; Dashboard and Pairing are
/// gone. Activity is a placeholder stub until a later PR. Holds the live
/// store; previews substitute the in-memory one behind the same protocols.
struct ContentView: View {
    @State private var store: LiveNilesStore
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
        case queue, activity, home, settings
        var id: String { rawValue }
    }

    @State private var selectedTab: NilesTab = {
    // Test/screenshot hook: `simctl launch ... -UITabSelect activity` opens a
    // given tab so per-tab captures don't need UI automation.
    let args = ProcessInfo.processInfo.arguments
    if let i = args.firstIndex(of: "-UITabSelect"), i + 1 < args.count {
        return NilesTab(rawValue: args[i + 1]) ?? .queue
    }
    return .queue
}()

    init(store: LiveNilesStore) {
        _store = State(initialValue: store)
    }

    private var pendingCount: Int { store.pendingProposals.count }

    var body: some View {
        TabView(selection: $selectedTab) {
            QueueScreen(model: store)
                .tabItem { Label("Queue", systemImage: "list.bullet.rectangle") }
                .badge(pendingCount)
                .tag(NilesTab.queue)
            if let fixture = fixtureActivityStore {
                ActivityScreen(model: fixture)
                    .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
                    .tag(NilesTab.activity)
            } else {
                ActivityScreen(model: store)
                    .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
                    .tag(NilesTab.activity)
            }
            HomeGraphScreen(model: store)
                .tabItem { Label("Home", systemImage: "square.grid.3x3") }
                .tag(NilesTab.home)
            SettingsScreen(model: store)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(NilesTab.settings)
        }
        .task {
            store.start()
            await store.seedQueueFixtureIfRequested()
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
