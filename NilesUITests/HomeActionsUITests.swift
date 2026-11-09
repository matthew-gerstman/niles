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
        let labelBefore = queueButton.label

        // Full-swipe right: stages the primary action (Run scene). Nothing
        // applies — the proposal lands in the queue, visible as the badge.
        let start = scene.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        let end = scene.coordinate(withNormalizedOffset: CGVector(dx: 1.6, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end)
        sleep(2)

        XCTAssertNotEqual(
            queueButton.label, labelBefore,
            "Staging from Home should raise the queue badge without applying anything"
        )
        capture("home-staged-scene-run", in: app)

        // Swipe left past the open threshold: quick actions snap open.
        let revealStart = scene.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        let revealEnd = scene.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        revealStart.press(forDuration: 0.05, thenDragTo: revealEnd)
        sleep(1)
        capture("home-quick-actions", in: app)

        // The staged proposal is the same normal queue entry agents produce.
        queueButton.tap()
        XCTAssertTrue(app.staticTexts["Good Morning"].waitForExistence(timeout: 10))
        capture("queue-staged-proposal", in: app)
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
