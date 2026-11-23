import XCTest

/// App Store pictures, made from sample data. Run by the App Store Connect workflow on a large iPhone
/// and a 13-inch iPad; each picture is kept as an attachment named "store-NN-…".
final class StoreScreenshotsUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testStoreScreenshots() {
        // 1. The welcome story.
        var app = XCUIApplication()
        app.launchArguments += ["--reset-welcome", "--ui-fast"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Everyone's ready.\nYour phone isn't."].waitForExistence(timeout: 15)
                      || app.buttons.firstMatch.waitForExistence(timeout: 5))
        sleep(2)
        keep(app, "store-01-welcome")
        app.terminate()

        // 2. Free up: the Dial and everything it found.
        app = XCUIApplication()
        app.launchArguments += ["--skip-welcome", "--demo", "--ui-fast"]
        app.launch()
        XCTAssertTrue(app.buttons["row-duplicates"].waitForExistence(timeout: 15))
        sleep(1)
        keep(app, "store-02-free-up")

        // 3. A list to pick from, with what is selected.
        let videos = app.buttons["row-videos"]
        reveal(videos, in: app)
        videos.tap()
        XCTAssertTrue(app.navigationBars["Large videos"].waitForExistence(timeout: 5))
        let pick = app.buttons["select-sample-11"]
        if pick.waitForExistence(timeout: 5) { pick.tap() }
        sleep(1)
        keep(app, "store-03-pick")
        app.terminate()

        // 4–5. Archive: groups made for you, and topics.
        app = XCUIApplication()
        app.launchArguments += ["--skip-welcome", "--demo-archive", "--pro", "--ui-fast"]
        app.launch()
        app.tabBars.buttons["Archive"].tap()
        XCTAssertTrue(app.buttons["group-large-videos"].waitForExistence(timeout: 15))
        sleep(1)
        keep(app, "store-04-archive")
        app.buttons["section-topics"].tap()
        XCTAssertTrue(app.buttons["group-topic-food"].waitForExistence(timeout: 5))
        sleep(1)
        keep(app, "store-05-topics")

        // 6. Where copies can go.
        app.buttons["section-videos"].tap()
        let group = app.buttons["group-large-videos"]
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        group.tap()
        let next = app.buttons["skim-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.tap()
        XCTAssertTrue(app.staticTexts["copy-summary"].waitForExistence(timeout: 10))
        sleep(1)
        keep(app, "store-06-copy")
        app.terminate()

        // For App Review: where Pro is bought (the in-app purchase review screenshot).
        app = XCUIApplication()
        app.launchArguments += ["--skip-welcome", "--ui-fast"]
        app.launch()
        app.tabBars.buttons["More"].tap()
        let pro = app.buttons["more-pro"]
        XCTAssertTrue(pro.waitForExistence(timeout: 10))
        pro.tap()
        XCTAssertTrue(app.navigationBars["TidyAway Pro"].waitForExistence(timeout: 10))
        sleep(3)
        keep(app, "store-review-pro")
    }

    /// Scrolls until the element is clear of the floating bottom button, as the dashboard tests do.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            let bar = app.buttons["review-next"]
            let clear = !bar.exists || (element.exists && element.frame.maxY < bar.frame.minY - 8)
            if element.exists && element.isHittable && clear { return }
            let list = app.collectionViews.firstMatch
            if list.exists { list.swipeUp(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
        }
    }

    private func keep(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
