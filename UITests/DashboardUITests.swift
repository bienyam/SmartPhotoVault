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
        XCTAssertTrue(app.buttons["row-duplicates"].waitForExistence(timeout: 60))
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
        let duplicates = app.buttons["row-duplicates"]
        guard duplicates.waitForExistence(timeout: 60) else {
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
        XCTAssertTrue(app.buttons["select-sample-1"].exists, "The copy to keep is listed.")
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
        XCTAssertFalse(app.buttons["select-sample-1"].exists, "Only screenshots are listed.")
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
        let rows = ["more-activity": "Activity", "more-analyze": "Analyze storage", "more-pro": "TidyAway Pro",
                    "guide-messages": "Messages attachments", "more-icloud-downloads": "Remove a file download",
                    "more-large-files": "Analyze selected files", "more-optimize": "Keep smaller copies",
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

    func testAdvancedAnalysisIsProAndOffersThePurchaseCalmly() {
        let app = launch()
        app.tabBars.buttons["More"].tap()
        app.buttons["more-analyze"].tap()
        let advanced = app.buttons["Advanced analysis"]
        if !advanced.isHittable { app.swipeUp() }
        advanced.tap()
        XCTAssertTrue(app.navigationBars["TidyAway Pro"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["pro-restore"].waitForExistence(timeout: 15), "Restore is always offered.")
        app.buttons["Not now"].tap()
        XCTAssertTrue(app.navigationBars["Analyze storage"].waitForExistence(timeout: 5))
    }

    func testProUnlockedShowsAsUnlocked() {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-welcome", "--pro"]
        app.launch()
        app.tabBars.buttons["More"].tap()
        app.buttons["more-pro"].tap()
        XCTAssertTrue(app.staticTexts["Pro is unlocked."].waitForExistence(timeout: 5))
    }

    func testStorageQuestionnaireRecommendsAnOptionUsersCanReview() {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-welcome", "--pro"]
        app.launch()
        XCTAssertTrue(app.navigationBars["TidyAway"].waitForExistence(timeout: 15))
        app.tabBars.buttons["More"].tap()
        app.buttons["more-analyze"].tap()
        XCTAssertTrue(app.navigationBars["Analyze storage"].waitForExistence(timeout: 5))
        let advanced = app.buttons["Advanced analysis"]
        if !advanced.isHittable { app.swipeUp() }
        advanced.tap()
        XCTAssertTrue(app.navigationBars["Advanced analysis"].waitForExistence(timeout: 5))
        app.buttons["Free up phone space"].tap()
        app.buttons["Yes"].tap()
        app.buttons["See my analysis now"].tap()
        XCTAssertTrue(app.navigationBars["Storage & cost analysis"].waitForExistence(timeout: 5))
        app.buttons["Compare alternatives"].tap()
        XCTAssertTrue(app.navigationBars["Compare alternatives"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Suggested for your goal"].exists)
        app.buttons["Optimize iPhone Storage"].tap()
        XCTAssertTrue(app.navigationBars["Optimize iPhone Storage"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Compare alternatives"].waitForExistence(timeout: 5))
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
        XCTAssertTrue(app.staticTexts["One-time unlock. Never a subscription."].exists)
        XCTAssertTrue(app.staticTexts["Archive up to 5 GB, with every copy checked"].exists)
        XCTAssertTrue(app.buttons["pro-restore"].waitForExistence(timeout: 15))
    }

    func testArchiveTabHasMoveOutAndGetBack() {
        let app = launch()
        app.tabBars.buttons["Archive"].tap()
        XCTAssertTrue(app.staticTexts["Make an archive copy"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["TidyAway only adds copies to your archive. It never deletes or changes anything there, by design."].exists)
        let files = app.buttons["Pick files myself"]
        reveal(files, in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 5))
        app.buttons["Get back"].tap()
        XCTAssertTrue(app.staticTexts["Nothing archived yet."].waitForExistence(timeout: 5)
                      || app.staticTexts["Archived items"].exists)
        app.buttons["Move out"].tap()
        XCTAssertTrue(app.staticTexts["Make an archive copy"].waitForExistence(timeout: 5))
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
        let list = app.collectionViews.firstMatch
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            list.swipeUp(velocity: .slow)
        }
    }
}
