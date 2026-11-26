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
        app.launchArguments += ["--skip-welcome", "--demo", "--ui-fast", "--store-pictures"]
        app.launch()
        XCTAssertTrue(app.buttons["row-duplicates"].waitForExistence(timeout: 15))
        sleep(1)
        keep(app, "store-02-free-up")

        // The Storage Checkup after a step: free space rose.
        let checkup = app.buttons["storage-checkup"]
        if checkup.waitForExistence(timeout: 5), checkup.isHittable {
            checkup.tap()
            if app.staticTexts["checkup-gained"].waitForExistence(timeout: 10) {
                sleep(1)
                keep(app, "store-09-checkup")
            }
            let back = app.navigationBars.buttons.firstMatch
            if back.waitForExistence(timeout: 5) { back.tap() }
            _ = app.buttons["row-duplicates"].waitForExistence(timeout: 10)
        }

        // 3. A list to pick from, with what is selected.
        let videos = app.buttons["row-videos"]
        reveal(videos, in: app)
        videos.tap()
        XCTAssertTrue(app.navigationBars["Large videos"].waitForExistence(timeout: 5))
        // Three videos picked.
        for id in ["sample-13", "sample-10", "sample-11"] {
            let pick = app.buttons["select-\(id)"]
            if pick.waitForExistence(timeout: 5) { pick.tap() }
        }
        // The sign-off ticked, so the picture shows Delete ready. Delete itself is never tapped.
        let signoff = app.buttons["signoff"]
        if signoff.waitForExistence(timeout: 5) { signoff.tap() }
        sleep(1)
        keep(app, "store-03-pick")

        // The second look: every video picked, the sign-off ticked, Delete tapped. With sample data
        // this only opens TidyAway's own "not backed up" check. "Delete anyway" is never tapped,
        // and Delete is only tapped when the selection is known to include items that aren't backed up.
        let all = app.buttons["select-all"]
        if all.waitForExistence(timeout: 5) { all.tap() }
        if signoff.waitForExistence(timeout: 5) { signoff.tap() }
        let delete = app.buttons["delete-selected"]
        if delete.waitForExistence(timeout: 5), delete.isEnabled, delete.label.contains("12") {
            delete.tap()
            if app.staticTexts["backup-title"].waitForExistence(timeout: 10) {
                sleep(1)
                keep(app, "store-08-second-look")
            }
        }
        app.terminate()

        // 4–5. Archive: groups made for you, and topics.
        app = XCUIApplication()
        app.launchArguments += ["--skip-welcome", "--demo-archive", "--pro", "--ui-fast", "--store-pictures"]
        app.launch()
        openTab("Archive", in: app)
        XCTAssertTrue(app.buttons["group-large-videos"].waitForExistence(timeout: 15))
        sleep(1)
        keep(app, "store-04-archive")
        app.buttons["section-topics"].tap()
        XCTAssertTrue(app.buttons["group-topic-food"].waitForExistence(timeout: 15))
        sleep(1)
        keep(app, "store-05-topics")

        // Get back: what was archived, by day.
        let getBack = app.buttons["archive-get-back"]
        if getBack.waitForExistence(timeout: 5) {
            getBack.tap()
            if app.buttons["archive-day"].firstMatch.waitForExistence(timeout: 10) {
                sleep(2)
                keep(app, "store-10-get-back")
            }
            app.buttons["archive-move-out"].tap()
            sleep(1)
        }

        // 6. Where copies can go.
        app.buttons["section-videos"].tap()
        let group = app.buttons["group-large-videos"]
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        group.tap()
        let next = app.buttons["skim-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        next.tap()
        XCTAssertTrue(app.staticTexts["copy-summary"].waitForExistence(timeout: 10))
        // A place chosen and the sign-off ticked, so the picture shows Copy ready.
        let place = app.buttons["iCloud Drive"].firstMatch
        XCTAssertTrue(place.waitForExistence(timeout: 5))
        place.tap()
        let consent = app.buttons["archive-consent"]
        XCTAssertTrue(consent.waitForExistence(timeout: 5))
        consent.tap()
        sleep(1)
        keep(app, "store-06-copy")

        // 7. The finished screen: copied and checked. With --store-pictures nothing is really copied.
        let copy = app.buttons["archive-copy"]
        XCTAssertTrue(copy.isEnabled)
        copy.tap()
        XCTAssertTrue(app.staticTexts["completion-title"].waitForExistence(timeout: 10))
        sleep(5)
        keep(app, "store-07-verified")
        app.terminate()

        // For App Review: where Pro is bought (the in-app purchase review screenshot).
        app = XCUIApplication()
        app.launchArguments += ["--skip-welcome", "--ui-fast"]
        app.launch()
        openTab("More", in: app)
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

    /// iPhone shows a tab bar; iPad shows the tabs as buttons along the top.
    private func openTab(_ name: String, in app: XCUIApplication) {
        let bar = app.tabBars.buttons[name]
        if bar.waitForExistence(timeout: 3) { bar.tap() } else { app.buttons[name].firstMatch.tap() }
    }

    private func keep(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

/// Footage for the App Store preview video: the real app, walked through at a person's pace while the
/// workflow records the simulator screen. Sample data only; nothing is copied or deleted.
final class PreviewFootageUITests: XCTestCase {
    private var marks: [[String: Any]] = []

    override func setUp() {
        continueAfterFailure = true
    }

    func testPreviewFootage() {
        // Take 1. Free up: the Storage Score, a list to pick from, and the second look.
        var app = XCUIApplication()
        app.launchArguments += ["--skip-welcome", "--demo", "--store-pictures"]
        app.launch()
        if app.buttons["row-duplicates"].waitForExistence(timeout: 20) {
            sleep(1)
            mark("home")
            sleep(5)
            app.swipeUp(velocity: .slow)
            sleep(2)
            mark("home-scrolled")
            let videos = app.buttons["row-videos"]
            for _ in 0..<6 where !(videos.exists && videos.isHittable) { app.swipeUp(velocity: .slow) }
            if videos.exists {
                videos.tap()
                if app.navigationBars["Large videos"].waitForExistence(timeout: 8) {
                    mark("pick")
                    sleep(2)
                    for id in ["sample-13", "sample-14", "sample-15"] {
                        let pick = app.buttons["select-\(id)"]
                        if pick.waitForExistence(timeout: 5) { pick.tap() }
                        usleep(900_000)
                    }
                    sleep(1)
                    let signoff = app.buttons["signoff"]
                    if signoff.waitForExistence(timeout: 5) { signoff.tap() }
                    sleep(2)
                    mark("pick-end")
                    // Two of the three aren't in the sample archive, so Delete opens TidyAway's own
                    // check. "Delete anyway" is never tapped.
                    let delete = app.buttons["delete-selected"]
                    if delete.waitForExistence(timeout: 5), delete.isEnabled, delete.label.contains("3") {
                        delete.tap()
                        if app.staticTexts["backup-title"].waitForExistence(timeout: 10) {
                            mark("second-look")
                            sleep(5)
                            mark("second-look-end")
                        }
                    }
                }
            }
        }
        app.terminate()

        // Take 2. Archive: a group, where the copy goes, and copied and checked.
        app = XCUIApplication()
        app.launchArguments += ["--skip-welcome", "--demo-archive", "--pro", "--store-pictures"]
        app.launch()
        openTab("Archive", in: app)
        if app.buttons["group-large-videos"].waitForExistence(timeout: 20) {
            sleep(1)
            mark("archive")
            sleep(3)
            app.buttons["section-videos"].tap()
            let group = app.buttons["group-large-videos"]
            if group.waitForExistence(timeout: 8) {
                sleep(1)
                group.tap()
                let next = app.buttons["skim-next"]
                if next.waitForExistence(timeout: 10) {
                    mark("skim")
                    sleep(2)
                    next.tap()
                    if app.staticTexts["copy-summary"].waitForExistence(timeout: 10) {
                        mark("copy")
                        sleep(2)
                        let place = app.buttons["iCloud Drive"].firstMatch
                        if place.waitForExistence(timeout: 5) { place.tap() }
                        sleep(1)
                        let consent = app.buttons["archive-consent"]
                        if consent.waitForExistence(timeout: 5) { consent.tap() }
                        sleep(2)
                        mark("copy-end")
                        let copy = app.buttons["archive-copy"]
                        if copy.exists, copy.isEnabled {
                            copy.tap()
                            if app.staticTexts["completion-title"].waitForExistence(timeout: 15) {
                                mark("verified")
                                sleep(6)
                                mark("verified-end")
                            }
                        }
                    }
                }
            }
        }
        app.terminate()

        // Take 3. Get back: what was archived, by day.
        app = XCUIApplication()
        app.launchArguments += ["--skip-welcome", "--demo-archive", "--pro", "--store-pictures"]
        app.launch()
        openTab("Archive", in: app)
        let getBack = app.buttons["archive-get-back"]
        if getBack.waitForExistence(timeout: 20) {
            sleep(2)
            mark("archive-2")
            getBack.tap()
            if app.buttons["archive-day"].firstMatch.waitForExistence(timeout: 10) {
                mark("get-back")
                sleep(4)
                app.buttons["archive-day"].firstMatch.tap()
                sleep(4)
                mark("get-back-end")
            }
        }
        app.terminate()

        // Take 4. The Storage Checkup with free space risen.
        app = XCUIApplication()
        app.launchArguments += ["--skip-welcome", "--demo", "--store-pictures"]
        app.launch()
        let checkup = app.buttons["storage-checkup"]
        if checkup.waitForExistence(timeout: 20), checkup.isHittable {
            sleep(2)
            mark("home-2")
            checkup.tap()
            if app.staticTexts["checkup-gained"].waitForExistence(timeout: 10) {
                mark("checkup")
                sleep(5)
                mark("checkup-end")
            }
        }
        app.terminate()

        let data = (try? JSONSerialization.data(withJSONObject: marks)) ?? Data()
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "preview-marks"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func mark(_ name: String) {
        marks.append(["name": name, "time": Date().timeIntervalSince1970])
    }

    private func openTab(_ name: String, in app: XCUIApplication) {
        let bar = app.tabBars.buttons[name]
        if bar.waitForExistence(timeout: 5) { bar.tap() } else { app.buttons[name].firstMatch.tap() }
    }
}
