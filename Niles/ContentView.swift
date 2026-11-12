import SwiftUI
import NilesCore

/// Root view: Home, Activity, and — when the agent feature gate allows it
/// (AgentGate) — Niles. At generous widths (measured, not size-class, so
/// base iPhones in landscape qualify) Home and Activity sit side by side
/// with no tab bar; at compact widths they are tabs, with Niles as the
/// agent chat as a first-class tab. Holds the live store; previews
/// substitute the in-memory one behind the same protocols.
struct ContentView: View {
    @State private var store: LiveNilesStore
    @State private var navigation = AppNavigation.shared
    /// The agent feature gate, bound live: toggling it in Settings re-renders
    /// the tab row here without a relaunch.
    @AppStorage(AgentGate.storageKey) private var agentEnabled = AgentGate.bundledDefault
    /// Screenshot/preview hook: `-UIActivityFixtures` renders the Activity tab
    /// on the fixture store instead of the live one, so a fresh simulator has
    /// a populated timeline to capture.
    @State private var fixtureActivityStore: FixtureActivityStore? = {
        if ProcessInfo.processInfo.arguments.contains("-UIActivityFixtures") {
            return FixtureActivityStore()
        }
        return nil
    }()
    /// Screenshot/preview hook: `-UIHomeFixtures` renders the Home tab on the
    /// in-memory fixture store, so a fresh simulator shows a populated queue
    /// and paired agents without Keychain credentials or live sessions.
    @State private var fixtureHomeStore: InMemoryNilesStore? = {
        if ProcessInfo.processInfo.arguments.contains("-UIHomeFixtures") {
            return InMemoryNilesStore()
        }
        return nil
    }()
    /// Screenshot hook: `-UIProposalDetail <id>` presents that proposal's
    /// detail sheet directly — per-proposal captures don't need UI
    /// automation (same family as `-UITabSelect`). Fixture ids are random,
    /// so a tool name also matches, preferring a proposal that already has
    /// read-back evidence. No-op with no match.
    @State private var fixtureDetailProposal: NilesProposal?
    /// Minimum width at which Home and Activity sit side by side. Measured
    /// window width, not horizontal size class — so base iPhones in
    /// landscape qualify too.
    private static let wideLayoutMinWidth: CGFloat = 600
    /// Live measured width of the root view; drives the adaptive layout.
    @State private var measuredWidth: CGFloat = 0
    /// Wide layout only: presents the gated agent chat as a sheet (the
    /// toolbar button on the Home pane opens it).
    @State private var showWideChat = false

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

    /// Screenshot hook: `-UIWideLayout [on|off]` pins the adaptive layout —
    /// bare or `on` forces the side-by-side panes even at compact width,
    /// `off` forces the tab pair even at generous width (same family as
    /// `-UITabSelect`, so captures need no UI automation).
    private static func forcedWideLayout() -> Bool? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-UIWideLayout") else { return nil }
        return i + 1 < args.count && args[i + 1].lowercased() == "off" ? false : true
    }

    /// The adaptive decision: a forced hook wins, else the measured width.
    private var usesWideLayout: Bool {
        if let forced = Self.forcedWideLayout() { return forced }
        return measuredWidth >= Self.wideLayoutMinWidth
    }

    var body: some View {
        Group {
            if usesWideLayout {
                wideLayout
            } else {
                tabLayout
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
        .task {
            store.start()
            AgentGate.toggleFixtureIfRequested()
            await store.seedQueueFixtureIfRequested()
            // Screenshot hook: open one proposal's detail sheet directly.
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-UIProposalDetail"), i + 1 < args.count {
                let target = args[i + 1]
                fixtureDetailProposal = store.proposals.first { $0.id == target }
                    ?? store.proposals.first { $0.tool == target && !$0.evidence.isEmpty }
                    ?? store.proposals.first { !$0.evidence.isEmpty }
                    // Pendings have no evidence yet; only reached when no
                    // executed proposal matches, so executed stays preferred.
                    ?? store.proposals.first { $0.tool == target }
            }
            // The wide layout has no tab row; `-UITabSelect niles` opens
            // the chat sheet instead.
            if usesWideLayout, selectedTab == .niles {
                selectedTab = .home
                showWideChat = true
            }
        }
        .sheet(item: $fixtureDetailProposal) { proposal in
            ProposalDetailSheet(proposal: proposal, undoState: store.undoStates[proposal.id])
        }
        .sheet(isPresented: $showWideChat) {
            NavigationStack { AgentChatScreen(model: store) }
        }
        // Deep link from OpenQueueIntent while the app is already running.
        .onChange(of: navigation.queueSelectionPending) { _, pending in
            guard pending else { return }
            selectedTab = .home
            navigation.consumeQueueSelection()
        }
    }

    /// Compact layout (the pre-adaptive root): the Home / Activity /
    /// (gated) Niles tab pair.
    private var tabLayout: some View {
        TabView(selection: $selectedTab) {
            if let fixtureHomeStore {
                HomeScreen(model: fixtureHomeStore)
                    .tabItem { Label("Home", systemImage: "house") }
                    .tag(NilesTab.home)
            } else {
                HomeScreen(model: store)
                    .tabItem { Label("Home", systemImage: "house") }
                    .badge(pendingCount)
                    .tag(NilesTab.home)
            }
            if let fixture = fixtureActivityStore {
                ActivityScreen(model: fixture)
                    .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
                    .tag(NilesTab.activity)
            } else {
                ActivityScreen(model: store)
                    .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
                    .tag(NilesTab.activity)
            }
            if agentEnabled {
                NavigationStack {
                    AgentChatScreen(model: store)
                }
                .tabItem { Label("Niles", systemImage: "sparkles") }
                .tag(NilesTab.niles)
            }
        }
    }

    /// Generous-width layout: Home and Activity side by side, each keeping
    /// its own NavigationStack title, with no tab bar. The gated agent chat
    /// stays reachable through a trailing toolbar button on the Home pane.
    private var wideLayout: some View {
        HStack(spacing: 0) {
            if let fixtureHomeStore {
                HomeScreen(model: fixtureHomeStore, chatEntry: chatEntry)
            } else {
                HomeScreen(model: store, chatEntry: chatEntry)
            }
            Divider()
            if let fixture = fixtureActivityStore {
                ActivityScreen(model: fixture)
            } else {
                ActivityScreen(model: store)
            }
        }
    }

    /// The wide layout's chat entry: gated, opening the sheet above.
    private var chatEntry: (() -> Void)? {
        agentEnabled ? { showWideChat = true } : nil
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
