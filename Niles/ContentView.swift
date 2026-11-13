import SwiftUI
import NilesCore

/// Root view: Home and Activity. At generous widths (measured, not
/// size-class, so base iPhones in landscape qualify) they sit side by side
/// with no tab bar — Activity left, Home right — with the pane split
/// aligned to the device's crease when one is reported (Duo, iOS 27.1+).
/// At compact widths there is also no tab bar: a single page with Home
/// above Activity. The gated agent chat (AgentGate) is reachable from
/// either layout through a trailing button on Home's bar, opening the chat
/// as a sheet. Holds the live store; previews substitute the in-memory one
/// behind the same protocols.
struct ContentView: View {
    @State private var store: LiveNilesStore
    @State private var navigation = AppNavigation.shared
    /// The agent feature gate, bound live: toggling it in Settings re-renders
    /// Home's chat entry here without a relaunch.
    @AppStorage(AgentGate.storageKey) private var agentEnabled = AgentGate.bundledDefault
    /// Screenshot/preview hook: `-UIActivityFixtures` renders the Activity
    /// pane on the fixture store instead of the live one, so a fresh
    /// simulator has a populated timeline to capture.
    @State private var fixtureActivityStore: FixtureActivityStore? = {
        if LaunchArguments.uiActivityFixtures {
            return FixtureActivityStore()
        }
        return nil
    }()
    /// Screenshot/preview hook: `-UIHomeFixtures` renders the Home pane on
    /// the in-memory fixture store, so a fresh simulator shows a populated
    /// queue and paired agents without Keychain credentials or live sessions.
    @State private var fixtureHomeStore: InMemoryNilesStore? = {
        if LaunchArguments.uiHomeFixtures {
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
    /// Presents the gated agent chat as a sheet: the trailing button on
    /// Home's bar opens it in both layouts (the compact single page has no
    /// Niles tab either).
    @State private var showChatSheet = false

    init(store: LiveNilesStore) {
        _store = State(initialValue: store)
    }

    /// The adaptive decision: a forced hook wins, else the measured width.
    private var usesWideLayout: Bool {
        if let forced = LaunchArguments.uiWideLayout { return forced }
        return measuredWidth >= Self.wideLayoutMinWidth
    }

    var body: some View {
        Group {
            if usesWideLayout {
                wideLayout
            } else {
                compactLayout
            }
        }
        // Safe-area diagnostics: -UISafeAreaProbe overlays the root's
        // measured insets and boundary lines (see SafeAreaProbe).
        .overlay {
            if SafeAreaProbe.active {
                SafeAreaOverlay(label: usesWideLayout ? "root-wide" : "root-compact")
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { measuredWidth = $0 }
        .task {
            store.start()
            AgentGate.toggleFixtureIfRequested()
            await store.seedQueueFixtureIfRequested()
            await store.seedProposalsFixtureIfRequested()
            // Screenshot hook: open one proposal's detail sheet directly.
            if let target = LaunchArguments.uiProposalDetail {
                fixtureDetailProposal = store.queue.proposals.first { $0.id == target }
                    ?? store.queue.proposals.first { $0.tool == target && !$0.evidence.isEmpty }
                    ?? store.queue.proposals.first { !$0.evidence.isEmpty }
                    // Pendings have no evidence yet; only reached when no
                    // executed proposal matches, so executed stays preferred.
                    ?? store.queue.proposals.first { $0.tool == target }
            }
            // Test/screenshot hook: `simctl launch ... -UITabSelect niles`
            // opens the agent chat so its capture doesn't need UI
            // automation. There are no tabs anymore — the single page shows
            // Home and Activity together — so niles is the only meaningful
            // value; home/activity are no-ops (both panes already visible).
            if LaunchArguments.uiTabSelect == "niles" {
                showChatSheet = true
            }
            // Deep link from OpenQueueIntent: a cold launch lands on the
            // page whose Home pane holds the staged proposals awaiting
            // approval. Consuming the selection here leaves the
            // scroll-to-Queue signal for HomeScreen to act on.
            if navigation.queueSelectionPending {
                navigation.consumeQueueSelection()
            }
        }
        .sheet(item: $fixtureDetailProposal) { proposal in
            ProposalDetailSheet(proposal: proposal, undoState: store.queue.undoStates[proposal.id])
        }
        .sheet(isPresented: $showChatSheet) {
            NavigationStack { AgentChatScreen(chat: store.chat, agentStatus: store.agentStatus, queue: store.queue) }
        }
        // Deep link from OpenQueueIntent while the app is already running:
        // consume the selection so HomeScreen's scroll-to-Queue signal
        // fires (HomeScreen observes it directly).
        .onChange(of: navigation.queueSelectionPending) { _, pending in
            guard pending else { return }
            navigation.consumeQueueSelection()
        }
    }

    /// Compact layout: ONE page, no tab bar — Home's sections with
    /// Activity's appended below, all in a single list, so the page scrolls
    /// like any phone page (Home above Activity) instead of two half-height
    /// panes each confined to half the screen. That half-and-half structure
    /// is what read as "a weird half thing" on the folded Duo — not a
    /// misclassification: the folded window is compact-width and correctly
    /// chose this layout. The gated agent chat stays reachable through the
    /// same trailing button on Home's bar the wide layout uses (chatEntry).
    private var compactLayout: some View {
        if let fixtureHomeStore {
            HomeScreen(dashboard: fixtureHomeStore, pairing: fixtureHomeStore, queue: fixtureHomeStore,
                       chatEntry: chatEntry,
                       activityModel: fixtureActivityStore ?? store.queue)
        } else {
            HomeScreen(dashboard: store.dashboard, pairing: store.pairing, queue: store.queue,
                       chatEntry: chatEntry,
                       activityModel: fixtureActivityStore ?? store.queue)
        }
    }

    /// Generous-width layout: Activity and Home side by side — Activity on
    /// the left, Home on the right — each keeping its own NavigationStack
    /// title, with no tab bar. The pane split follows the device's crease
    /// when one is reported (`activityPaneWidth`); otherwise it is equal.
    /// The gated agent chat stays reachable through a trailing toolbar
    /// button on the Home pane. Both panes pass through `widePane()` so
    /// their horizontal list margins match (observed in simulation:
    /// landscape safe-area clearance otherwise folds into the
    /// edge-adjacent pane's list item insets).
    private var wideLayout: some View {
        GeometryReader { proxy in
            let activityWidth = activityPaneWidth(in: proxy)
            HStack(spacing: 0) {
                if let fixture = fixtureActivityStore {
                    ActivityScreen(model: fixture)
                        .widePane()
                        .frame(width: activityWidth)
                } else {
                    ActivityScreen(model: store.queue)
                        .widePane()
                        .frame(width: activityWidth)
                }
                Divider()
                if let fixtureHomeStore {
                    HomeScreen(dashboard: fixtureHomeStore, pairing: fixtureHomeStore, queue: fixtureHomeStore, chatEntry: chatEntry)
                        .widePane()
                } else {
                    HomeScreen(dashboard: store.dashboard, pairing: store.pairing, queue: store.queue, chatEntry: chatEntry)
                        .widePane()
                }
            }
        }
    }

    /// The wide layout's Activity pane width: when the device reports an
    /// active vertical division region (the Duo's crease — ReservedRegion,
    /// iOS 27.1+, read from the same proxy that measures this pane), the
    /// Activity pane extends through the crease's region so Home starts
    /// clear of the fold, making Activity wider than the equal split. Any
    /// other report falls back to the equal split: no active region (the
    /// device open flat reports none), a horizontal division (laptop pose —
    /// a leading/trailing split cannot follow it), or a split that would
    /// not leave Activity at least its half. `-UICreasePosition` forces a
    /// crease at a fraction of the width so the aligned split is capturable
    /// on simulators that report no region.
    private func activityPaneWidth(in proxy: GeometryProxy) -> CGFloat {
        let width = proxy.size.width
        if let fraction = LaunchArguments.uiCreasePosition {
            return max(width * fraction, width / 2)
        }
        if #available(iOS 27.1, *) {
            if let crease = proxy.reservedRegions(kind: .division)
                .first(where: { $0.isActive }),
                // A vertical crease line only: the region is tall and narrow
                // when the fold runs top-to-bottom (book pose, portrait).
                crease.frame.height > crease.frame.width {
                let split = crease.frame.maxX
                if split.isFinite, split >= width / 2, split < width {
                    return split
                }
            }
        }
        return width / 2
    }

    /// The chat entry shared by both layouts: gated, opening the sheet above.
    private var chatEntry: (() -> Void)? {
        agentEnabled ? { showChatSheet = true } : nil
    }
}

// MARK: - Wide pane normalization

/// One modifier for BOTH wideLayout panes, so their horizontal list margins
/// match regardless of which window edge a pane abuts, and so their bar
/// geometry matches too. The scroll-content margins themselves live on each
/// pane's List (ActivityScreen/HomeScreen): scoped to the NavigationStack
/// they interfere with the bar's scroll-edge tracking in the wide layout.
/// Observed on Xcode 27.2 simulators: in landscape, SwiftUI distributes
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
/// Bar geometry: in the wide layout
/// the leading pane never registers the top scroll-edge effect — the system
/// status pillar sits over the trailing pane's x-range — so its bar falls
/// back to the legacy expanded large-title geometry (110 pt, title below an
/// empty 58 pt inline zone) while the trailing pane compacts to 58 pt.
/// Normalizing both panes with a shared inline title pin covers the class.
/// The pin travels through the widePaneInlineTitle environment key rather
/// than .navigationBarTitleDisplayMode() here: the latter cannot be set
/// from outside a pane's NavigationStack (probed on the Duo simulator —
/// the modifier on widePane() left the leading pane at 110 pt), so each
/// pane's List reads the key and applies it inside its own stack.
fileprivate extension View {
    func widePane() -> some View {
        listStyle(.insetGrouped)
            .environment(\.widePaneInlineTitle, true)
    }
}

private struct WidePaneInlineTitleKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether a pane pins inline title mode on its bar. Set by widePane()
    /// for the wide layout's two panes; the narrow layout reads the default
    /// false (automatic title mode), keeping its large titles untouched.
    /// A Bool rather than the title-mode type itself: the SDK type name
    /// (NavigationBarTitleDisplayMode / NavigationBar.TitleDisplayMode) has
    /// shifted across iOS SDKs, while the modifier call is stable.
    var widePaneInlineTitle: Bool {
        get { self[WidePaneInlineTitleKey.self] }
        set { self[WidePaneInlineTitleKey.self] = newValue }
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
