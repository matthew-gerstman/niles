import Foundation
import Testing
@testable import NilesCore

/// The Activity row's two-line title split (2026-11-14): a proposal title
/// with a `“…”` quoted entity renders its action as the headline and the
/// entity as a secondary second line; titles without a quote keep their
/// one-line treatment. Pure string derivation, no fixtures.
@Suite struct ProposalTitlePartsTests {

    // MARK: - Split titles

    @Test func splitsServiceGroupTitle() {
        #expect(ProposalTitleParts.split("Create service group “Bedroom blinds”")
            == ProposalTitleParts.Parts(action: "Create service group", entity: "Bedroom blinds"))
    }

    @Test func splitsSceneTitle() {
        #expect(ProposalTitleParts.split("Run scene “Good Morning”")
            == ProposalTitleParts.Parts(action: "Run scene", entity: "Good Morning"))
    }

    @Test func splitsAtFirstQuoteOnly() {
        // The rename's second quoted span stays part of the entity: the row
        // names what the first quote acts on, not the rename target.
        #expect(ProposalTitleParts.split("Rename “Kitchen” to “Cookery”")
            == ProposalTitleParts.Parts(action: "Rename", entity: "Kitchen"))
    }

    // MARK: - One-line titles

    @Test func unquotedTitleReturnsNil() {
        #expect(ProposalTitleParts.split("Move Office into Upstairs") == nil)
    }

    @Test func undoTitleWithoutQuoteReturnsNil() {
        #expect(ProposalTitleParts.split("Undo — Move Office into Upstairs") == nil)
    }

    @Test func leadingQuoteReturnsNil() {
        // No action before the quote — nothing to render as the headline.
        #expect(ProposalTitleParts.split("“Orphan” title") == nil)
    }
}
