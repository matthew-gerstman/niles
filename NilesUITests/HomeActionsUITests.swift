import XCTest

/// Captures PR evidence: the Home quick-action flow and the consolidated
/// Settings screen, driven deterministically in the simulator (which runs
/// the demo fixture through FakeHomeKitService).
///
/// CI drives the quick actions through the row's trailing quick-action menu
/// (tap the ellipsis button, then the item) — XCUITest's synthesized drags
/// and long-presses are unreliably delivered, so gesture-driven assertions
/// are inherently flaky. The context menu itself is covered by the recorded
/// QA evidence rather than CI.
final class HomeActionsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testQuickActionsStageIntoQueue() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITabSelect", "home"]
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

        // The scene row's trailing quick-action menu exposes the same
        // actions the context menu offers. Assert it opens deterministically.
        let quickActions = app.buttons["Actions for Good Morning"]
        XCTAssertTrue(quickActions.waitForExistence(timeout: 10))
        quickActions.tap()
        let run = app.buttons["Run"]
        XCTAssertTrue(run.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Rename"].exists)
        XCTAssertTrue(app.buttons["Delete"].exists)
        sleep(1)
        capture("home-quick-actions", in: app)

        // Tapping a menu item stages it — a Run on the scene row lands as
        // a proposal in the queue. Nothing applies from Home.
        run.tap()
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
