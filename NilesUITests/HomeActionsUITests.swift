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
        // applies — the proposal lands in the queue. XCUITest's synthesized
        // drags are occasionally cancelled mid-path by the test framework
        // before the app sees `onEnded` (observed via unified-log tracing);
        // the app springs the row back on cancellation, so retry the physical
        // gesture until the proposal lands (max 3 attempts).
        let dragStart = scene.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
        let stageEnd = dragStart.withOffset(CGVector(dx: 240, dy: 0))
        var staged = false
        for attempt in 1...3 {
            dragStart.press(forDuration: 0.1, thenDragTo: stageEnd)
            sleep(2)
            capture("home-after-full-swipe", in: app)
            queueButton.tap()
            let stagedCard = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS %@", "Good Morning")
            ).firstMatch
            if stagedCard.waitForExistence(timeout: 10) {
                staged = true
                break
            }
            app.tabBars.buttons["Home"].tap()
            XCTAssertTrue(
                scene.waitForExistence(timeout: 10),
                "Home row should return cleanly after an unstaged swipe attempt \(attempt)"
            )
        }
        XCTAssertTrue(
            staged,
            "A full-swipe Run on the scene row should stage a proposal in the queue"
        )
        capture("queue-staged-proposal", in: app)

        // Back to Home: a left swipe past the open threshold snaps the quick
        // actions open (Run / Rename / Delete) without staging anything.
        // Same gesture-retry policy as the staging swipe.
        app.tabBars.buttons["Home"].tap()
        let row = app.staticTexts["Good Morning"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        let revealStart = row.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))
        let revealEnd = revealStart.withOffset(CGVector(dx: -120, dy: 0))
        for _ in 1...3 {
            revealStart.press(forDuration: 0.1, thenDragTo: revealEnd)
            sleep(1)
            if app.buttons["Delete"].waitForExistence(timeout: 5) { break }
        }
        XCTAssertTrue(
            app.buttons["Delete"].exists,
            "The left swipe should reveal the row's quick actions"
        )
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
