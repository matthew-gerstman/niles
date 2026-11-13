import Testing
@testable import NilesCore

/// The review card's echo rules (`ProposalCardEcho`): which member lines
/// merely restate their operation's header and must not render. Pinpoints
/// the Nov 13 feedback — an `assign_accessory_to_room` batch rendered each
/// move as a header plus a detail row that restated it ('Accessory "X" ·
/// "Home Assistant" → "Outdoor"' under 'Move accessory "X" to Outdoor');
/// only the source room is new and it carries no decision weight. Scene
/// and characteristic operations keep their detail rows: there the
/// ' → ' transition IS the payload. Serialization is untouched — these
/// predicates run on the persisted strings, so old batches parse
/// identically.
@Suite struct ProposalCardEchoTests {

    // MARK: - Accessory moves: the detail row is a pure echo

    @Test func moveDetailRowIsEcho() {
        #expect(ProposalCardEcho.isMoveEcho(
            "Accessory “Outdoor Forest adventure” · “Home Assistant” → “Outdoor”",
            ofTitle: "Move accessory “Outdoor Forest adventure” to Outdoor"
        ))
    }

    @Test func moveFromNoRoomIsEchoToo() {
        // An unassigned accessory moves with 'no room' as the source —
        // still nothing the header lacks.
        #expect(ProposalCardEcho.isMoveEcho(
            "Accessory “Outdoor Cosmos” · no room → “Outdoor”",
            ofTitle: "Move accessory “Outdoor Cosmos” to Outdoor"
        ))
    }

    @Test func moveEchoRequiresMatchingName() {
        // A different accessory's row under a move header would be real
        // detail — never dropped.
        #expect(!ProposalCardEcho.isMoveEcho(
            "Accessory “Outdoor Cosmos” · “Home Assistant” → “Outdoor”",
            ofTitle: "Move accessory “Outdoor Snow sparkle” to Outdoor"
        ))
    }

    @Test func moveEchoRequiresMoveHeader() {
        // The predicate exists for the move header shape; other headers
        // never suppress an 'Accessory …' row through it.
        #expect(!ProposalCardEcho.isMoveEcho(
            "Accessory “Outdoor Cosmos” · “Home Assistant” → “Outdoor”",
            ofTitle: "Identify accessory “Outdoor Cosmos”"
        ))
    }

    // MARK: - Other operations: their detail rows carry the payload

    @Test func characteristicWriteKeepsItsTransitionRow() {
        // 'Set "X" Brightness to 50' + '… Brightness 73 → 50' — the row
        // carries old → new; the header has no values.
        let text = "Characteristic “Brightness” · 73 → 50"
        #expect(!ProposalCardEcho.isEcho(text, ofTitle: "Set “Desk Lamp” Brightness to 50"))
        #expect(!ProposalCardEcho.isMoveEcho(text, ofTitle: "Set “Desk Lamp” Brightness to 50"))
    }

    @Test func sceneActionEditKeepsItsRow() {
        let text = "“Good Morning” · add action Kitchen Lights On → 1"
        #expect(!ProposalCardEcho.isEcho(text, ofTitle: "Update scene “Good Morning”"))
        #expect(!ProposalCardEcho.isMoveEcho(text, ofTitle: "Update scene “Good Morning”"))
    }

    @Test func sceneEchoHeaderRowStillDrops() {
        // PR #109's class, unchanged: a created-with-actions tail restates
        // the header.
        #expect(ProposalCardEcho.isEcho(
            "Scene “Movie Time” · created with 1 action",
            ofTitle: "Create scene “Movie Time”"
        ))
    }

    @Test func renameTransitionRowStillRenders() {
        // 'Scene "A" → "B"' under 'Rename scene "A"' — the right side is
        // the new name the header lacks (PR #109 explicitly kept it).
        #expect(!ProposalCardEcho.isEcho(
            "Scene “Good Morning” → “Wake Up”",
            ofTitle: "Rename scene “Good Morning”"
        ))
    }

    @Test func accessoryRowUnderMoveHeaderNotCaughtByGenericEcho() {
        // The move row is a ' → ' transition — the generic predicate never
        // matched it (why the moves needed their own rule).
        #expect(!ProposalCardEcho.isEcho(
            "Accessory “Outdoor Forest adventure” · “Home Assistant” → “Outdoor”",
            ofTitle: "Move accessory “Outdoor Forest adventure” to Outdoor"
        ))
    }
}
