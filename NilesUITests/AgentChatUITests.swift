import XCTest

/// Captures PR evidence for the in-app agent chat (spec art_AL0RolQe): the
/// Home-tab entry row, the four transcript states (empty, running, staged,
/// unavailable), and the proposal chip's deep link into the Queue. The
/// `-UIChatFixtures` launch argument stands in for the Foundation Models
/// runner so the send path stages through the real proposal store on
/// machines without Apple Intelligence — the same trick `-UISeedQueue` uses.
final class AgentChatUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testChatSendStagesAndDeepLinksToQueue() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITabSelect", "home", "-UIChatFixtures"]
        app.launch()

        // Entry row: pushes the dedicated chat screen (not a sheet).
        let entry = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Ask Niles")
        ).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "The Home tab carries the Ask Niles entry row")
        sleep(1)
        tapCenter(of: entry, in: app)
        XCTAssertTrue(
            app.navigationBars["Ask Niles"].waitForExistence(timeout: 10),
            "The entry row pushes the dedicated chat screen"
        )

        // Empty state: states the gate up front, composer where the thumb is.
        XCTAssertTrue(
            app.staticTexts["Requests stage proposals for your review — nothing changes until you approve in the Queue."]
                .waitForExistence(timeout: 10)
        )
        capture("chat-empty", in: app)

        // Send: optimistic user row, then the running turn.
        let composer = composerField(in: app)
        XCTAssertTrue(composer.waitForExistence(timeout: 10), "The composer text field is present")
        composer.tap()
        composer.typeText("Dim the living room lights tonight at 8")
        app.buttons["Send"].tap()

        XCTAssertTrue(
            app.staticTexts["Dim the living room lights tonight at 8"].waitForExistence(timeout: 5),
            "The user row lands optimistically"
        )
        // The fixture holds the run open for two seconds — capture mid-run.
        XCTAssertTrue(app.staticTexts["Working on the home graph…"].waitForExistence(timeout: 5))
        capture("chat-running", in: app)

        // Staged: summary verbatim from the run, proposal chip beneath it.
        let summary = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Staged 1 proposal")
        ).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 15), "The agent row carries the run summary verbatim")
        let chip = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "Movie Time")
        ).firstMatch
        XCTAssertTrue(chip.waitForExistence(timeout: 10), "The turn's staged proposal renders as a chip")
        capture("chat-staged", in: app)

        // Deep link: the chip opens the Queue with that proposal's review.
        chip.tap()
        XCTAssertTrue(
            app.buttons["Approve"].waitForExistence(timeout: 10),
            "The chip lands on the tapped proposal's Queue review"
        )
        capture("queue-deep-link", in: app)

        // The gate stays intact: dismissal is the sheet's native drag
        // gesture; closing it must leave the proposal staged in the Queue.
        app.swipeDown()
        XCTAssertTrue(app.navigationBars["Queue"].waitForExistence(timeout: 10))
    }

    @MainActor
    func testChatUnavailableState() throws {
        let app = XCUIApplication()
        // No -UIChatFixtures: the real gate decides, and a simulator without
        // Apple Intelligence reports unavailable.
        app.launchArguments += ["-UITabSelect", "home"]
        app.launch()

        let entry = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "Ask Niles")
        ).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 15))
        tapCenter(of: entry, in: app)
        XCTAssertTrue(app.navigationBars["Ask Niles"].waitForExistence(timeout: 10))

        // Unavailable: the gate's reason, verbatim with Settings — and a
        // composer that stays disabled. No degraded fallback.
        XCTAssertTrue(
            app.staticTexts["Niles' agent isn't available"].waitForExistence(timeout: 10)
        )
        XCTAssertFalse(app.buttons["Send"].isEnabled, "The composer disables when the gate failed")
        capture("chat-unavailable", in: app)
    }

    // MARK: - Helpers

    /// The vertical-axis composer surfaces to XCUITest as a text field or a
    /// text view depending on OS rendering; match it by identifier either way.
    @MainActor
    private func composerField(in app: XCUIApplication) -> XCUIElement {
        // A vertical-axis TextField morphs between a text field and a text
        // view as it gains focus — match both renderings with one query that
        // re-resolves on every snapshot.
        app.descendants(matching: .any)
            .matching(identifier: "chat-composer")
            .firstMatch
    }

    /// SwiftUI List rows intermittently report an invalid activation point
    /// while the list settles (see HomeActionsUITests) — tap by coordinate,
    /// re-resolving until the frame is valid.
    @MainActor
    private func tapCenter(of element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 {
            let frame = element.frame
            if frame.origin.x.isFinite, frame.width > 1, frame.height > 1 {
                app.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: frame.midX, dy: frame.midY))
                    .tap()
                return
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        element.tap()
    }

    @MainActor
    private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
