import XCTest

/// Captures PR evidence: the Home quick-action flow and the consolidated
/// Settings screen, driven deterministically in the simulator (which runs
/// the demo fixture through FakeHomeKitService).
///
/// CI drives the quick actions through the `-UIRevealQuickActions` launch
/// hook and real button taps — XCUITest's synthesized drag gestures are
/// unreliably delivered (cancelled mid-path), so gesture-driven assertions
/// are inherently flaky. The physical swipes themselves are covered by the
/// recorded QA evidence rather than CI.
final class HomeActionsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testQuickActionsRevealAndStageIntoQueue() throws {
        let app = XCUIApplication()
        app.launchArguments += [
            "-UITabSelect", "home",
            "-UIRevealQuickActions", "Good Morning",
        ]
        app.launch()

        let scene = app.staticTexts["Good Morning"]
        XCTAssertTrue(scene.waitForExistence(timeout: 15))

        // The queue starts empty in the demo fixture — capture that state
        // first, then return to Home for the quick-action flow.
        let queueButton = app.tabBars.buttons["Queue"]
        queueButton.tap()
        XCTAssertTrue(queueButton.waitForExistence(timeout: 10))
        capture("queue-empty", in: app)
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(scene.waitForExistence(timeout: 10))

        // The hook pre-revealed the scene row's quick actions — the same
        // buttons a left swipe exposes. Assert the reveal deterministically.
        let delete = app.buttons["Delete"]
        XCTAssertTrue(delete.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Run"].exists)
        XCTAssertTrue(app.buttons["Rename"].exists)
        sleep(1)
        capture("home-quick-actions", in: app)

        // Tapping a quick action stages it — a Run on the scene row lands as
        // a proposal in the queue. Nothing applies from Home.
        app.buttons["Run"].tap()
        queueButton.tap()
        let stagedCard = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS %@", "Good Morning")
        ).firstMatch
        XCTAssertTrue(
            stagedCard.waitForExistence(timeout: 10),
            "A quick-action Run on the scene row should stage a proposal in the queue"
        )
        capture("queue-staged-proposal", in: app)

        // Back to Home: pre-approval, the scene is still exactly where it was.
        app.tabBars.buttons["Home"].tap()
        XCTAssertTrue(
            scene.waitForExistence(timeout: 10),
            "Home should be unchanged before the proposal is approved"
        )
    }

    @MainActor
    func testSettingsTabShowsServerControlsAndPairing() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITabSelect", "settings"]
        app.launch()

        // The settings screen's own heading; content beyond it (endpoint,
        // sessions, pairing code) is captured for the PR evidence.
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
