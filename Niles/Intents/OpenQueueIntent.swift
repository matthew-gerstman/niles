import AppIntents

/// Process-wide navigation signal from App Intents into the UI. App Intents
/// cannot drive SwiftUI state directly, so the intent sets the flag and
/// ContentView consumes it on change — and at init for a cold launch.
@MainActor
@Observable
final class AppNavigation {
    static let shared = AppNavigation()

    private(set) var queueSelectionPending = false
    /// Retarget of the deep link onto the three-tab IA: the Queue now lives
    /// as a section inside Home, so a queue request also asks HomeScreen to
    /// scroll to that section and briefly highlight it.
    private(set) var scrollToQueuePending = false
    /// Optional proposal context riding the same signal: the chat's proposal
    /// chips request the Queue with the tapped proposal, so the Queue can
    /// open that proposal's detail directly. Siri and the tab bar never set
    /// it — plain `requestQueue()` keeps its old shape.
    private(set) var pendingProposalId: String?

    func requestQueue(proposalId: String? = nil) {
        queueSelectionPending = true
        scrollToQueuePending = true
        pendingProposalId = proposalId
    }

    /// Clears the tab-level signal. ContentView consumes this on change and
    /// at cold launch; the proposal context is consumed by the Queue itself
    /// (it may need the store's next poll to have loaded the proposal).
    func consumeQueueSelection() { queueSelectionPending = false }

    /// Clears the scroll-to-Queue-section signal once HomeScreen has
    /// scrolled there. Survives a cold launch's tab selection so the Home
    /// screen consumes it on appear.
    func consumeScrollToQueue() { scrollToQueuePending = false }

    /// Clears the proposal context once the Queue has opened the proposal.
    func consumePendingProposal() { pendingProposalId = nil }
}

/// The deep link into the Queue, where staged proposals wait for human
/// approval — the review hand-off for an Ask-Niles run. It only navigates;
/// approving or denying stays a human action in the app.
struct OpenQueueIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Queue"
    static let description = IntentDescription(
        "Opens Niles' Queue, where staged proposals wait for your approval."
    )

    static let openAppWhenRun = true

    /// Injectable for tests: the unit-test bundle runs hosted inside the real
    /// app, where the live ContentView consumes the shared signal mid-test —
    /// the UI doing its job makes a test that asserts on `.shared` fail. A
    /// fresh instance keeps the assertion hermetic. Production uses `.shared`.
    @MainActor static var navigationTarget = AppNavigation.shared

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // AppNavigation is MainActor-isolated; the intent hops over to set the
        // flag, then returns.
        await Self.navigationTarget.requestQueue()
        return .result(dialog: "Opening the Queue — staged proposals are waiting for your approval.")
    }
}
