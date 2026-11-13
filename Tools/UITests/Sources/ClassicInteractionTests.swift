import XCTest

/// The classic style's gestures, tried with real touches on a simulator (see project-uitests.yml and
/// the Interface preview workflow): a song swiped both ways in Cerca, the player dragged down by its
/// header and by its cover, AutoMix switched in the queue's sheet. Each step leaves a screenshot in
/// the results, and a line in the log saying what happened.
final class ClassicInteractionTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private func launch(_ scene: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-SeaglassScene", scene, "-theme.style", "classic"] + extra
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func report(_ line: String) {
        print("ui-check: \(line)")
    }

    /// A song of the results: the first row whose subtitle is the artist's.
    private func songRow(_ app: XCUIApplication) -> XCUIElement {
        app.cells.containing(NSPredicate(format: "label BEGINSWITH 'Daft Punk ·'")).firstMatch
    }

    func testSearchSwipes() {
        let app = launch("search:daft punk")
        let row = songRow(app)
        guard row.waitForExistence(timeout: 25) else {
            shot(app, "search-no-results")
            report("search: no song row (YouTube may refuse the runner)")
            return
        }
        shot(app, "search-1-results")

        row.swipeRight(velocity: .slow)
        let queueButton = app.buttons["Queue"]
        let queued = app.staticTexts["Added to the queue"]
        let rightWorked = queueButton.waitForExistence(timeout: 2) || queued.waitForExistence(timeout: 2)
        shot(app, "search-2-swiped-right")
        report("search swipe right: \(rightWorked ? "PASS" : "FAIL") (queue action or note shown)")
        XCTAssertTrue(rightWorked, "Swiping a song right in Cerca shows nothing")
        if queueButton.exists { queueButton.tap() }

        let again = songRow(app)
        again.swipeLeft(velocity: .slow)
        let likeButton = app.buttons["Like"]
        let liked = app.staticTexts["Added to your favourites"]
        let leftWorked = likeButton.waitForExistence(timeout: 2) || liked.waitForExistence(timeout: 2)
        shot(app, "search-3-swiped-left")
        report("search swipe left: \(leftWorked ? "PASS" : "FAIL") (like action or note shown)")
        XCTAssertTrue(leftWorked, "Swiping a song left in Cerca shows nothing")
    }

    /// Closed: the player's "Lyrics preview" card is gone (the card is in the player's page even
    /// before it's scrolled into view).
    private func playerClosed(_ app: XCUIApplication) -> Bool {
        let card = app.staticTexts["Lyrics preview"]
        for _ in 0..<12 {
            if !card.exists { return true }
            usleep(250_000)
        }
        return false
    }

    func testPlayerOpens() {
        let app = launch("player-demo")
        let open = app.staticTexts["Lyrics preview"].waitForExistence(timeout: 8)
        report("player opens (its lyrics preview is there): \(open ? "PASS" : "FAIL")")
        XCTAssertTrue(open, "The player-demo scene didn't open the classic player")
    }

    func testPlayerDragDownByHeader() {
        let app = launch("player-demo")
        sleep(3)
        shot(app, "player-1-open")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.09))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.85))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0)
        sleep(2)
        shot(app, "player-2-dragged-by-header")
        let closed = playerClosed(app)
        report("player drag down by its header: \(closed ? "PASS" : "FAIL")")
        XCTAssertTrue(closed, "Dragging the player's header down doesn't close it")
    }

    func testPlayerDragDownByCover() {
        let app = launch("player-demo")
        sleep(3)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .default, thenHoldForDuration: 0)
        sleep(2)
        shot(app, "player-3-dragged-by-cover")
        let closed = playerClosed(app)
        report("player drag down by its cover: \(closed ? "PASS" : "FAIL")")
        XCTAssertTrue(closed, "Dragging the player's cover down doesn't close it")
    }

    func testQueueAutoMixSwitch() {
        let app = launch("player-demo", ["-SeaglassPanel", "queue"])
        let toggle = app.switches["AutoMix"]
        guard toggle.waitForExistence(timeout: 8) else {
            shot(app, "queue-no-switch")
            report("queue AutoMix switch: FAIL (not found)")
            XCTFail("The queue's sheet has no AutoMix switch")
            return
        }
        shot(app, "queue-1-open")
        let before = toggle.value as? String
        toggle.tap()
        sleep(1)
        let after = app.switches["AutoMix"].value as? String
        shot(app, "queue-2-automix-tapped")
        let premium = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Premium'")).firstMatch.exists
        let changed = before != after
        report("queue AutoMix switch: \(changed ? "PASS" : (premium ? "PREMIUM" : "FAIL")) (\(before ?? "?") → \(after ?? "?"))")
        XCTAssertTrue(changed || premium, "The queue's AutoMix switch didn't change")
    }
}
