import Foundation
import NilesCore
import Testing
@testable import Niles

/// The chat screen's pure pieces (spec art_AL0RolQe): the proposal deep
/// link's navigation flags and the chip's live-state mapping.
@MainActor
struct ChatNavigationTests {

    // MARK: - AppNavigation proposal context

    @Test
    func chipTapRequestsQueueWithProposalContext() {
        let navigation = AppNavigation()

        navigation.requestQueue(proposalId: "prop-1")

        #expect(navigation.queueSelectionPending)
        #expect(navigation.pendingProposalId == "prop-1")

        // ContentView consumes the tab-level flag; the Queue consumes the
        // proposal context once it has opened the proposal.
        navigation.consumeQueueSelection()
        #expect(!navigation.queueSelectionPending)
        #expect(navigation.pendingProposalId == "prop-1")

        navigation.consumePendingProposal()
        #expect(navigation.pendingProposalId == nil)
    }

    @Test
    func plainQueueRequestCarriesNoProposalContext() {
        // Siri's OpenQueueIntent keeps its old shape — no proposal context.
        let navigation = AppNavigation()
        navigation.requestQueue()

        #expect(navigation.queueSelectionPending)
        #expect(navigation.pendingProposalId == nil)
    }

    // MARK: - Chip live-state mapping

    @Test
    func chipLabelsEveryProposalState() {
        #expect(AgentChatChip.stateLabel(for: .staged) == "Staged — awaiting your review")
        #expect(AgentChatChip.stateLabel(for: .approved) == "Approved")
        #expect(AgentChatChip.stateLabel(for: .executed) == "Executed")
        #expect(AgentChatChip.stateLabel(for: .denied) == "Denied")
        #expect(AgentChatChip.stateLabel(for: .expired) == "Expired")
        #expect(AgentChatChip.stateLabel(for: .failed) == "Failed")
    }

    @Test
    func chipDefaultsToStagedBeforeThePollSurfacesTheProposal() {
        // A freshly resolved turn stages the proposal; until the store's
        // 1-second poll surfaces it the chip reads the state a run produces.
        #expect(AgentChatChip.stateLabel(for: nil) == "Staged — awaiting your review")
        #expect(AgentChatChip.symbol(for: nil) == AgentChatChip.symbol(for: .staged))
    }
}
