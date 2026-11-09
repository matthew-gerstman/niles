import XCTest

/// Captures PR evidence: the Home swipe-to-stage flow and the consolidated
/// Settings screen, driven as real gestures in the simulator (which runs the
/// demo fixture through FakeHomeKitService).
final class HomeActionsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testFullSwipeStagesPrimaryActionAndRevealsQuickActions() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITabSelect", "home"]
        app.launch()

        let scene = app.staticTexts["Good Morning"]
        XCTAssertTrue(scene.waitForExistence(timeout: 15))

        let queueButton = app.tabBars.buttons["Queue"]

        // The queue starts empty in the demo fixture — capture that state
        // first, then return to Home for the swipe flow.
        queueButton.tap()
        XCTAssertTrue(queueButton.waitForExistence(timeout: 10))
        capture("queue-empty", in: app)
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(scene.waitForExistence(timeout: 10))

        // Full-swipe right: stages the primary action (Run scene). Nothing
        // applies — the proposal lands in the queue. Capture before asserting
        // so a failure still leaves visual evidence of the post-swipe state.
        let start = scene.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        let end = scene.coordinate(withNormalizedOffset: CGVector(dx: 1.6, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        sleep(2)
        capture("home-after-full-swipe", in: app)

        // The staged proposal is the same normal queue entry agents produce.
        queueButton.tap()
        let stagedCard = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Good Morning")
        ).firstMatch
        XCTAssertTrue(
            stagedCard.waitForExistence(timeout: 10),
            "A full-swipe Run on the scene row should stage a proposal in the queue"
        )
        capture("queue-staged-proposal", in: app)

        // Back to Home: a left swipe past the open threshold snaps the quick
        // actions open (Run / Rename / Delete) without staging anything.
        app.tabBars.buttons["Home"].tap()
        let row = app.staticTexts["Good Morning"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let revealStart = row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        let revealEnd = row.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        revealStart.press(forDuration: 0.05, thenDragTo: revealEnd)
        sleep(1)
        capture("home-quick-actions", in: app)
    }

    @MainActor
    func testSettingsTabShowsServerControlsAndPairing() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITabSelect", "settings"]
        app.launch()

        // The settings screen's own heading; content beyond it (endpoint,
        // sessions, QR pairing) is captured for the PR evidence.
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 15))
        capture("settings-consolidated", in: app)
    }

    @MainActor
    private func capture(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
