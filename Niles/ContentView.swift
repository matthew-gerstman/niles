import SwiftUI
import NilesCore

/// Root view: Home and Activity as ONE normal page — Home on top, Activity
/// below — at every width, phone or unfolded Duo alike (supersedes the
/// side-by-side crease-aware split from PR #97). There is no tab bar. The
/// gated agent chat (AgentGate) is reachable through a trailing button on
/// Home's bar, opening the chat as a sheet. Holds the live store; previews
/// substitute the in-memory one behind the same protocols.
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
    /// Presents the gated agent chat as a sheet: the trailing button on
    /// Home's bar opens it (the single page has no Niles tab either).
    @State private var showChatSheet = false

    init(store: LiveNilesStore) {
        _store = State(initialValue: store)
    }

    var body: some View {
        singlePage
        // Safe-area diagnostics: -UISafeAreaProbe overlays the root's
        // measured insets and boundary lines (see SafeAreaProbe).
        .overlay {
            if SafeAreaProbe.active {
                SafeAreaOverlay(label: "root")
            }
        }
        .task {
            store.start()
            AgentGate.toggleFixtureIfRequested()
            await store.seedQueueFixtureIfRequested()
            await store.seedProposalsFixtureIfRequested()
            // Screenshot hook: open one proposal's detail sheet directly.
            if let target = LaunchArguments.uiProposalDetail {
                fixtureDetailProposal = store.proposals.first { $0.id == target }
                    ?? store.proposals.first { $0.tool == target && !$0.evidence.isEmpty }
                    ?? store.proposals.first { !$0.evidence.isEmpty }
                    // Pendings have no evidence yet; only reached when no
                    // executed proposal matches, so executed stays preferred.
                    ?? store.proposals.first { $0.tool == target }
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
            ProposalDetailSheet(proposal: proposal, undoState: store.undoStates[proposal.id])
        }
        .sheet(isPresented: $showChatSheet) {
            NavigationStack { AgentChatScreen(model: store) }
        }
        // Deep link from OpenQueueIntent while the app is already running:
        // consume the selection so HomeScreen's scroll-to-Queue signal
        // fires (HomeScreen observes it directly).
        .onChange(of: navigation.queueSelectionPending) { _, pending in
            guard pending else { return }
            navigation.consumeQueueSelection()
        }
    }

    /// The one layout: a single normal page, no tab bar — Home on top,
    /// Activity below, a Divider between them; each half scrolls within its
    /// half of the page. The gated agent chat stays reachable through the
    /// trailing button on Home's bar (chatEntry).
    private var singlePage: some View {
        VStack(spacing: 0) {
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

    /// The chat entry: gated, opening the sheet above.
    private var chatEntry: (() -> Void)? {
        agentEnabled ? { showChatSheet = true } : nil
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
