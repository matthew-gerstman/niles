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

    /// Generous-width layout: Activity and Home side by side — Activity on
    /// the left, Home on the right — each keeping its own NavigationStack
    /// title, with no tab bar. The gated agent chat stays reachable through
    /// a trailing toolbar button on the Home pane. Both panes pass through
    /// `widePane()` so their horizontal list margins match (diagnosis
    /// art_RzbLOF98: landscape safe-area clearance otherwise folds into the
    /// edge-adjacent pane's list item insets).
    private var wideLayout: some View {
        HStack(spacing: 0) {
            if let fixture = fixtureActivityStore {
                ActivityScreen(model: fixture)
                    .widePane()
            } else {
                ActivityScreen(model: store)
                    .widePane()
            }
            Divider()
            if let fixtureHomeStore {
                HomeScreen(model: fixtureHomeStore, chatEntry: chatEntry)
                    .widePane()
            } else {
                HomeScreen(model: store, chatEntry: chatEntry)
                    .widePane()
            }
        }
    }

    /// The wide layout's chat entry: gated, opening the sheet above.
    private var chatEntry: (() -> Void)? {
        agentEnabled ? { showWideChat = true } : nil
    }
}

// MARK: - Wide pane normalization

/// One modifier for BOTH wideLayout panes, so their horizontal list margins
/// match regardless of which window edge a pane abuts, and so their bar
/// geometry matches too. The scroll-content margins themselves live on each
/// pane's List (ActivityScreen/HomeScreen): scoped to the NavigationStack
/// they interfere with the bar's scroll-edge tracking in the wide layout
/// (bisect cell 2, diagnosis art_LwUDWPuP).
/// Diagnosis (art_RzbLOF98, Xcode 27.2 simulators): in landscape, SwiftUI distributes
/// the window's horizontal safe area — the sensor-housing clearance (84 pt
/// on the Duo) — to the edge-adjacent children of wideLayout's HStack, and
/// an insetGrouped list folds that clearance into its item insets, leaving
/// Activity's cells ~68 pt further from their leading edge than Home's.
/// The list style is pinned so the
/// panes cannot drift apart. Not the #76 chrome class — no scene-level
/// glass is involved, so there is nothing to move onto a pane's own bar.
/// The clearance itself is physical: hardware verification governs whether
/// the shared margin must instead be the housing width (never negative
/// padding).
///
/// Bar geometry (bisect cell 3, diagnosis art_LwUDWPuP): in the wide layout
/// the leading pane never registers the top scroll-edge effect — the system
/// status pillar sits over the trailing pane's x-range — so its bar falls
/// back to the legacy expanded large-title geometry (110 pt, title below an
/// empty 58 pt inline zone) while the trailing pane compacts to 58 pt.
/// Normalizing both panes with a shared inline title pin covers the class.
/// The mode travels through the widePaneTitleMode environment key rather
/// than .navigationBarTitleDisplayMode() here: the latter cannot be set
/// from outside a pane's NavigationStack (probed on the Duo simulator —
/// the modifier on widePane() left the leading pane at 110 pt), so each
/// pane's List reads the key and applies it inside its own stack.
fileprivate extension View {
    func widePane() -> some View {
        listStyle(.insetGrouped)
            .environment(\.widePaneTitleMode, .inline)
    }
}

private struct WidePaneTitleModeKey: EnvironmentKey {
    static let defaultValue: NavigationBarTitleDisplayMode = .automatic
}

extension EnvironmentValues {
    /// Title mode a pane applies to its own navigation bar. Set by
    /// widePane() for the wide layout's two panes; the narrow layout reads
    /// the default .automatic, keeping its large titles untouched.
    var widePaneTitleMode: NavigationBarTitleDisplayMode {
        get { self[WidePaneTitleModeKey.self] }
        set { self[WidePaneTitleModeKey.self] = newValue }
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
