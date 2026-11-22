import XCTest

final class DashboardUITests: XCTestCase {
    // CI runs this once before the unit/integration suite to initialize PhotoKit's
    // authorization through the real consent UI, not only the simulator TCC preset.
    func testPrepareFullPhotoAccess() {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .photos)
        app.launchArguments += ["--skip-welcome"]
        app.launch()
        let start = app.buttons["free-up-space"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(springboard.alerts.firstMatch.exists, "Opening the app must not request Photos access.")
        start.tap()
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 10) else {
            XCTFail("Expected the Photos consent dialog after tapping Free up space.")
            return
        }
        let labels = ["Allow Full Access", "Allow Access to All Photos"]
        guard let allow = labels.map({ alert.buttons[$0] }).first(where: { $0.exists }) else {
            XCTFail("Full-access choice missing: \(alert.debugDescription)")
            return
        }
        allow.tap()
        XCTAssertTrue(app.buttons["check-again"].waitForExistence(timeout: 90), "The check should finish.")
        XCTAssertTrue(app.buttons["row-duplicates"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Authorized Free up results"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    func testAuthorizedLibraryScanReviewsRealResources() {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-welcome"]
        app.launch()
        let again = app.buttons["check-again"]
        let start = app.buttons["free-up-space"]
        XCTAssertTrue(again.waitForExistence(timeout: 15) || start.exists)
        if again.exists { again.tap() } else { start.tap() }
        XCTAssertTrue(app.buttons["check-again"].waitForExistence(timeout: 90), "The check should finish.")
        let duplicates = app.buttons["row-duplicates"]
        guard duplicates.waitForExistence(timeout: 5) else {
            XCTFail("Real Photos scan did not produce results: \(app.debugDescription)")
            return
        }
        duplicates.tap()
        XCTAssertTrue(app.navigationBars["Duplicates"].waitForExistence(timeout: 10))
        let fixture = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "SPV-test-")).firstMatch
        XCTAssertTrue(fixture.waitForExistence(timeout: 5), "Expected actual simulator-library fixture files in review.")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Real Photos duplicate scan"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    func testDeniedPhotosAccessShowsSettings() {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .photos)
        app.launchArguments += ["--skip-welcome"]
        app.launch()
        let start = app.buttons["free-up-space"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.tap()
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "Photo access should be requested only after Free up space is tapped.")
        let curlyApostrophe = alert.buttons["Don’t Allow"]
        let straightApostrophe = alert.buttons["Don't Allow"]
        if curlyApostrophe.exists { curlyApostrophe.tap() }
        else if straightApostrophe.exists { straightApostrophe.tap() }
        else { XCTFail("Expected a deny-access button: \(alert.debugDescription)"); return }
        XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Denied photo permission"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    func testFreeUpLeadsWithOneAction() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Storage full? Get your camera back."].exists)
        XCTAssertTrue(app.buttons["free-up-space"].exists || app.buttons["check-again"].exists,
                      "One action leads: start a check, or check again after a saved one.")
        XCTAssertEqual(app.tabBars.buttons.count, 3)
    }

    func testSampleDuplicateReview() {
        let app = launchWithSamples()
        app.buttons["row-duplicates"].tap()
        XCTAssertTrue(app.navigationBars["Duplicates"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["kept-sample-1"].exists, "The copy to keep is listed, not selectable.")
        XCTAssertTrue(app.staticTexts["Keeping this one"].exists)
        XCTAssertTrue(app.buttons["select-sample-2"].exists)
        XCTAssertFalse(app.buttons["select-sample-4"].exists, "A Live Photo with different motion is not a duplicate.")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Sample duplicate review"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDuplicateRemovalNeedsSelectionAndSignOff() {
        let app = launchWithSamples()
        app.buttons["row-duplicates"].tap()
        XCTAssertTrue(app.navigationBars["Duplicates"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["delete-selected"].exists, "Nothing is selected for you.")
        app.buttons["select-all"].tap()
        let delete = app.buttons["delete-selected"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertFalse(delete.isEnabled, "Removal stays off until the user signs off.")
        app.buttons["signoff"].tap()
        XCTAssertTrue(delete.isEnabled)
        delete.tap()
        XCTAssertTrue(app.staticTexts["Sample data. Nothing was removed."].waitForExistence(timeout: 5))
        XCTAssertFalse(delete.isEnabled, "Each removal needs a fresh sign-off.")
    }

    func testCategoryRemovalNeedsSelectionAndSignOff() {
        let app = launchWithSamples()
        app.buttons["row-screenshots"].tap()
        XCTAssertTrue(app.navigationBars["Screenshots"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["delete-selected"].exists, "Nothing is selected for you.")
        XCTAssertFalse(app.descendants(matching: .any)["kept-sample-1"].exists || app.buttons["select-sample-1"].exists, "Only screenshots are listed.")
        let pick = app.buttons["select-sample-6"]
        XCTAssertTrue(pick.waitForExistence(timeout: 5))
        pick.tap()
        let delete = app.buttons["delete-selected"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertFalse(delete.isEnabled, "Delete stays off until the sign-off is checked.")
        app.buttons["signoff"].tap()
        XCTAssertTrue(delete.isEnabled)
        delete.tap()
        XCTAssertTrue(app.staticTexts["Sample data. Nothing was removed."].waitForExistence(timeout: 5))
    }

    func testEveryFreeUpRowOpens() {
        let app = launchWithSamples()
        let rows = ["row-videos": "Large videos", "row-duplicates": "Duplicates",
                    "row-screenshots": "Screenshots", "row-more": "More types"]
        for (id, title) in rows {
            app.buttons[id].tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), "\(id) should open \(title)")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 5))
        }
        app.buttons["row-more"].tap()
        XCTAssertTrue(app.buttons["category-bursts"].waitForExistence(timeout: 5))
        app.buttons["category-gifs"].tap()
        XCTAssertTrue(app.navigationBars["GIFs"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["category-bursts"].tap()
        XCTAssertTrue(app.navigationBars["Bursts"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["select-all"].exists, "Bursts stay review-only.")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Bursts review only"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testEveryMoreRowOpens() {
        let app = launch()
        app.tabBars.buttons["More"].tap()
        let rows = ["more-activity": "Activity", "more-pro": "TidyAway Pro",
                    "guide-messages": "Messages attachments", "more-explainer": "Where your storage goes",
                    "more-optimize": "Keep smaller copies", "more-icloud-downloads": "Remove a file download",
                    "more-help": "Help & privacy"]
        for (id, title) in rows {
            let row = app.buttons[id]
            reveal(row, in: app)
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(id) is missing")
            row.tap()
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 5), "\(id) should open \(title)")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 5))
        }
    }

    func testProUnlockedShowsAsUnlocked() {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-welcome", "--pro"]
        app.launch()
        app.tabBars.buttons["More"].tap()
        app.buttons["more-pro"].tap()
        XCTAssertTrue(app.staticTexts["Pro is unlocked."].waitForExistence(timeout: 5))
    }

    func testMessagesAttachmentsGuideOpensWithoutAScan() {
        let app = launch()
        app.tabBars.buttons["More"].tap()
        app.buttons["guide-messages"].tap()
        XCTAssertTrue(app.navigationBars["Messages attachments"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Wait for the list to load, then tap Messages."].exists)
    }

    func testProOpensFromMore() {
        let app = launch()
        app.tabBars.buttons["More"].tap()
        app.buttons["more-pro"].tap()
        XCTAssertTrue(app.navigationBars["TidyAway Pro"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Monthly, or once for life. Your choice."].exists)
        XCTAssertTrue(app.buttons["pro-monthly"].waitForExistence(timeout: 5), "The monthly option is offered.")
        XCTAssertTrue(app.buttons["pro-lifetime"].exists, "The lifetime option is offered.")
        XCTAssertTrue(app.buttons["Terms of Use"].exists, "Subscription terms are linked.")
        XCTAssertTrue(app.buttons["Privacy Policy"].exists)
        XCTAssertTrue(app.staticTexts["Archive up to 5 GB, with every copy checked"].exists)
        XCTAssertTrue(app.buttons["pro-restore"].waitForExistence(timeout: 15))
    }

    func testArchiveTabHasMoveOutAndGetBack() {
        let app = launch()
        app.tabBars.buttons["Archive"].tap()
        let moveOut = app.buttons["archive-move-out"], getBack = app.buttons["archive-get-back"]
        XCTAssertTrue(moveOut.waitForExistence(timeout: 10))
        XCTAssertTrue(getBack.exists)
        XCTAssertGreaterThan(moveOut.frame.height, 80, "Move out and Get back are large buttons.")
        XCTAssertGreaterThan(getBack.frame.height, 80)
        XCTAssertTrue(moveOut.isSelected)
        let promise = app.descendants(matching: .any)["archive-write-only"].firstMatch
        reveal(promise, in: app)
        XCTAssertTrue(promise.exists)
        let files = app.buttons["Pick files myself"]
        reveal(files, in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        keepScreenshot(of: app, named: "Archive move out")
        getBack.tap()
        XCTAssertTrue(app.staticTexts["Nothing archived yet."].waitForExistence(timeout: 5)
                      || app.descendants(matching: .any)["archive-day"].firstMatch.exists)
        keepScreenshot(of: app, named: "Archive get back")
        moveOut.tap()
        XCTAssertTrue(promise.waitForExistence(timeout: 5))
    }

    func testGoogleDriveAsksToConnectInsteadOfShowingFolders() {
        let app = launch()
        app.tabBars.buttons["Archive"].tap()
        let picker = app.buttons["storage-location"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        reveal(picker, in: app)
        picker.tap()
        let google = app.buttons["Google Drive"]
        XCTAssertTrue(google.waitForExistence(timeout: 5))
        google.tap()
        let connect = app.buttons["google-connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 5), "Google Drive offers a sign-in, not a folder list.")
        XCTAssertFalse(app.buttons["Choose archive folder in Files"].exists)
    }

    /// Regression guard: every archive destination that has shipped stays available.
    func testEveryArchiveDestinationIsStillOffered() {
        let app = launch()
        app.tabBars.buttons["Archive"].tap()
        let picker = app.buttons["storage-location"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        reveal(picker, in: app)
        picker.tap()
        for name in ["Drive plugged into this iPhone", "Google Drive", "iCloud Drive", "Other Files location",
                     "Home file server", "Another Apple Account"] {
            XCTAssertTrue(app.buttons[name].waitForExistence(timeout: 5), "\(name) must stay available.")
        }
        app.buttons["Drive plugged into this iPhone"].tap()
        XCTAssertTrue(app.buttons["Choose archive folder in Files"].waitForExistence(timeout: 5))
        keepScreenshot(of: app, named: "Archive destinations")
        let help = app.buttons["drive-help"]
        reveal(help, in: app)
        help.tap()
        XCTAssertTrue(app.staticTexts["Where to find it"].waitForExistence(timeout: 5))
        keepScreenshot(of: app, named: "Drive help")
        app.buttons["drive-help-done"].tap()
    }

    private func launchArchiveGroups(pro: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-welcome", "--demo-archive"] + (pro ? ["--pro"] : [])
        app.launch()
        app.tabBars.buttons["Archive"].tap()
        return app
    }

    func testAGroupOpensSelectedAndGoesToCopyInOneShot() {
        let app = launchArchiveGroups(pro: true)
        let group = app.buttons["group-large-videos"]
        XCTAssertTrue(group.waitForExistence(timeout: 15), "Very large videos is offered.")
        keepScreenshot(of: app, named: "Archive groups")
        let trip = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'group-trip'")).firstMatch
        XCTAssertTrue(trip.exists, "The trip is offered.")
        trip.tap()
        let next = app.buttons["skim-next"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        XCTAssertTrue(next.label.contains("120 items"), next.label)
        keepScreenshot(of: app, named: "Archive skim")
        app.buttons["skim-sample-trip0-0"].tap()
        XCTAssertTrue(next.label.contains("119 items"), "One tap leaves one out. \(next.label)")
        next.tap()
        XCTAssertTrue(app.staticTexts["copy-summary"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["copy-summary"].label.contains("119 items"))
        XCTAssertFalse(app.buttons["archive-copy"].isEnabled, "Nothing copies without a destination and sign-off.")
        keepScreenshot(of: app, named: "Archive copy")
    }

    func testGroupsNeedProButEveryoneSeesThem() {
        let app = launchArchiveGroups(pro: false)
        let group = app.buttons["group-large-videos"]
        XCTAssertTrue(group.waitForExistence(timeout: 15))
        group.tap()
        XCTAssertTrue(app.buttons["pro-monthly"].waitForExistence(timeout: 5), "Opening a group shows Pro.")
    }

    /// Regression guard: the filters that shipped stay available, free.
    func testArchiveFiltersAreStillAvailable() {
        let app = launchArchiveGroups(pro: false)
        let filter = app.buttons["archive-filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 15))
        reveal(filter, in: app)
        filter.tap()
        XCTAssertTrue(app.buttons["Show matching photos"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["archive-filters-pro"].exists)
        XCTAssertTrue(app.buttons["archive-suggest-videos"].exists)
    }

    /// Regression guard: restored features stay reachable.
    func testScanDetailsAndUnreadableItemsAreAvailable() {
        let app = launchWithSamples()
        let details = app.buttons["scan-details"]
        reveal(details, in: app)
        XCTAssertTrue(details.waitForExistence(timeout: 5))
        details.tap()
        XCTAssertTrue(app.navigationBars["Scan details"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Items checked"].exists)
        app.buttons["scan-unreadable"].tap()
        XCTAssertTrue(app.navigationBars["Couldn't read"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Cloud-only.heic"].exists)
    }

    func testFirstLaunchWelcomeLeadsToFreeUp() {
        let app = XCUIApplication()
        app.launchArguments += ["--reset-welcome"]
        app.launch()
        let start = app.buttons["Get started"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Nothing is removed until you approve it."].exists)
        start.tap()
        XCTAssertTrue(app.buttons["free-up-space"].waitForExistence(timeout: 10)
                      || app.buttons["check-again"].exists)
        XCTAssertTrue(app.tabBars.buttons["Archive"].exists)
    }

    func testWelcomeStorySkipLandsOnEveryWelcomeElement() {
        let app = XCUIApplication()
        app.launchArguments += ["--reset-welcome"]
        app.launch()
        let skip = app.buttons["welcome-skip"]
        XCTAssertTrue(skip.waitForExistence(timeout: 10), "The story should open with a Skip button.")
        keepScreenshot(of: app, named: "Welcome moment")
        skip.tap()
        XCTAssertTrue(app.buttons["Get started"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Try it with sample photos"].exists, "Samples are not offered to people.")
        XCTAssertTrue(app.staticTexts["Out of space? Let's fix it safely."].exists)
        XCTAssertTrue(app.staticTexts["The check runs on your iPhone. Your photos stay put."].exists)
        XCTAssertTrue(app.staticTexts["Nothing is removed until you approve it."].exists)
        XCTAssertTrue(app.staticTexts["Every change is logged and can be traced."].exists)
        XCTAssertFalse(app.buttons["welcome-skip"].exists, "Skip goes away on the last screen.")
        keepScreenshot(of: app, named: "Welcome payoff")
        app.buttons["Get started"].tap()
        XCTAssertTrue(app.buttons["free-up-space"].waitForExistence(timeout: 10)
                      || app.buttons["check-again"].exists)
        XCTAssertFalse(app.buttons["try-samples"].exists)
    }

    func testWelcomeStoryTapMovesOnAndEndsOnGetStarted() {
        let app = XCUIApplication()
        app.launchArguments += ["--reset-welcome"]
        app.launch()
        XCTAssertTrue(app.buttons["welcome-skip"].waitForExistence(timeout: 10))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        usleep(1_500_000)
        keepScreenshot(of: app, named: "Welcome scan")
        XCTAssertTrue(app.buttons["Get started"].waitForExistence(timeout: 15), "The story should end by itself.")
    }

    func testRecentlyDeletedGuideOpensWithClearStepsAndMeasures() {
        let app = launch()
        let card = app.buttons["recently-deleted-card"]
        XCTAssertTrue(card.waitForExistence(timeout: 10))
        card.tap()
        let measure = app.buttons["recently-deleted-measure"]
        XCTAssertTrue(app.staticTexts["Empty Recently Deleted"].waitForExistence(timeout: 5))
        keepScreenshot(of: app, named: "Recently Deleted guide")
        for _ in 0..<5 where !measure.isHittable { app.swipeUp() }
        measure.tap()
        XCTAssertTrue(app.descendants(matching: .any)["recently-deleted-result"].waitForExistence(timeout: 5))
        app.buttons["recently-deleted-done"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
    }

    private func keepScreenshot(of app: XCUIApplication, named name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-welcome"]
        app.launch()
        XCTAssertTrue(app.navigationBars["TidyAway"].waitForExistence(timeout: 15))
        return app
    }

    private func launchWithSamples() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-welcome", "--demo"]
        app.launch()
        XCTAssertTrue(app.buttons["row-duplicates"].waitForExistence(timeout: 15), "Sample results should load.")
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            // Lists scroll as collection views; Free up is a plain scroll view.
            let list = app.collectionViews.firstMatch
            if list.exists { list.swipeUp(velocity: .slow) } else { app.swipeUp(velocity: .slow) }
        }
    }
}
