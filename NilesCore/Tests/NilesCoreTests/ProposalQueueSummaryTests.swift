import Foundation
import Testing
@testable import NilesCore

/// The queue row's batch bullets (Matthew, 2026-11-13): one one-line bullet
/// per batch operation — the same succinct banner titles the detail card
/// groups on — capped with a '+N more' overflow line so long batches (an
/// 18-op batch, the QA fixture) stay compact. Pure string derivation, no
/// fixtures beyond card lines.
@Suite struct ProposalQueueSummaryTests {

    private func banner(_ number: Int, _ count: Int, _ title: String) -> String {
        "— Operation \(number) of \(count): \(title) —"
    }

    // MARK: - Banner parsing

    @Test func bannerParsesNumberCountTitle() {
        let fields = ProposalCardBanner.fields(
            of: "— Operation 2 of 4: Set “Lamp” Brightness to 50 —"
        )
        #expect(fields?.number == 2)
        #expect(fields?.count == 4)
        #expect(fields?.title == "Set “Lamp” Brightness to 50")
    }

    @Test func nonBannerLinesParseAsNil() {
        #expect(ProposalCardBanner.fields(of: "Scene “Starlight” · created with 2 actions") == nil)
        #expect(ProposalCardBanner.fields(of: "The scene stops working immediately.") == nil)
        #expect(ProposalCardBanner.fields(of: "— Operation X of 4: Title —") == nil)
    }

    // MARK: - Bullets

    @Test func oneBulletPerBatchOperation() {
        let bullets = ProposalQueueSummary.bullets(from: [
            banner(1, 2, "Delete scene “A”"),
            banner(2, 2, "Delete scene “B”"),
        ])
        #expect(bullets == ProposalQueueSummary.Bullets(
            lines: ["Delete scene “A”", "Delete scene “B”"], overflowCount: 0
        ))
    }

    @Test func longBatchCapsWithOverflowLine() {
        let eighteen = (1...18).map { banner($0, 18, "Delete scene “QA \($0)”") }
        let bullets = ProposalQueueSummary.bullets(from: eighteen)
        #expect(bullets.lines.count == ProposalQueueSummary.defaultCap)
        #expect(bullets.overflowCount == 14)
        #expect(bullets.lines.first == "Delete scene “QA 1”")
    }

    @Test func batchAtTheCapHasNoOverflow() {
        let four = (1...4).map { banner($0, 4, "Op \($0)") }
        let bullets = ProposalQueueSummary.bullets(from: four)
        #expect(bullets.lines.count == 4)
        #expect(bullets.overflowCount == 0)
    }

    @Test func nonBatchCardYieldsNoBullets() {
        // A single-op proposal's card carries no banners; the row keeps its
        // title-only treatment rather than restating the title.
        let bullets = ProposalQueueSummary.bullets(from: [
            "Scene “Starlight” · created with 2 actions",
            "The scene stops working immediately.",
        ])
        #expect(bullets.lines.isEmpty)
        #expect(bullets.overflowCount == 0)
    }
}
