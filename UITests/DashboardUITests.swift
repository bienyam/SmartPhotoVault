import XCTest

final class DashboardUITests: XCTestCase {
    // CI runs this once before the unit/integration suite to initialize PhotoKit's
    // authorization through the real consent UI, not only the simulator TCC preset.
    func testPrepareFullPhotoAccess() {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .photos)
        app.launchArguments += ["--skip-welcome"]
        app.launch()
        app.buttons["Check my photos"].tap()
        let scan = app.buttons["Scan Apple Photos"]
        XCTAssertTrue(scan.waitForExistence(timeout: 15))
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(springboard.alerts.firstMatch.exists, "Opening the dashboard must not request Photos access.")
        scan.tap()
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 10) else {
            XCTFail("Expected the Photos consent dialog after tapping Scan.")
            return
        }
        let labels = ["Allow Full Access", "Allow Access to All Photos"]
        guard let allow = labels.map({ alert.buttons[$0] }).first(where: { $0.exists }) else {
            XCTFail("Full-access choice missing: \(alert.debugDescription)")
            return
        }
        allow.tap()
        XCTAssertTrue(app.buttons["Rescan Apple Photos"].waitForExistence(timeout: 15))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Authorized Photos inventory"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    func testAuthorizedLibraryScanReviewsRealResources() {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-welcome"]
        app.launch()
        XCTAssertTrue(app.navigationBars["TidyAway"].waitForExistence(timeout: 15))
        app.buttons["Find duplicates"].tap()
        let scan = app.buttons["Find exact duplicates"]
        reveal(scan, in: app)
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        scan.tap()
        let review = app.buttons["Review duplicate groups"]
        reveal(review, in: app)
        guard review.waitForExistence(timeout: 15) else {
            XCTFail("Real Photos scan did not produce results: \(app.debugDescription)")
            return
        }
        review.tap()
        XCTAssertTrue(app.navigationBars["Exact duplicates"].waitForExistence(timeout: 10))
        let fixture = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "SPV-test-")).firstMatch
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
        app.buttons["Check my photos"].tap()
        let scan = app.buttons["Scan Apple Photos"]
        XCTAssertTrue(scan.waitForExistence(timeout: 15))
        scan.tap()
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "Photo access should be requested only after Scan is tapped.")
        let curlyApostrophe = alert.buttons["Don’t Allow"]
        let straightApostrophe = alert.buttons["Don't Allow"]
        if curlyApostrophe.exists { curlyApostrophe.tap() }
        else if straightApostrophe.exists { straightApostrophe.tap() }
        else { XCTFail("Expected a deny-access button: \(alert.debugDescription)"); return }
        let settings = app.buttons["Open Settings"]
        reveal(settings, in: app)
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Denied photo permission"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    func testDuplicateScanExplainsLocalOnlyScope() {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-welcome"]
        app.launch()
        app.buttons["Find duplicates"].tap()
        XCTAssertTrue(app.buttons["Find exact duplicates"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Scans files already available on this iPhone. Originals that require an iCloud download are left unverified."].exists)
        XCTAssertFalse(app.buttons["Scan with iCloud downloads"].exists)
    }

    func testSampleDuplicateReview() {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-welcome"]
        app.launch()
        XCTAssertTrue(app.navigationBars["TidyAway"].waitForExistence(timeout: 15))
        app.buttons["Find duplicates"].tap()
        let samples = app.buttons["Explore sample results"]
        reveal(samples, in: app)
        XCTAssertTrue(samples.waitForExistence(timeout: 5))
        samples.tap()
        XCTAssertTrue(app.staticTexts["Sample data — not your photo library"].firstMatch.waitForExistence(timeout: 5))
        let review = app.buttons["Review duplicate groups"]
        reveal(review, in: app)
        guard review.waitForExistence(timeout: 5) else {
            XCTFail("Duplicate review is missing. UI: \(app.debugDescription)")
            return
        }
        review.tap()
        XCTAssertTrue(app.navigationBars["Exact duplicates"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Beach.heic"].exists)
        XCTAssertTrue(app.staticTexts["Beach copy.heic"].exists)
        XCTAssertFalse(app.staticTexts["Different motion.heic"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Sample duplicate review"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testStorageQuestionnaireRecommendsAnOptionUsersCanReview() {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-welcome"]
        app.launch()
        app.buttons["Analyze storage & cost"].tap()
        app.buttons["Free up phone space"].tap()
        XCTAssertTrue(app.navigationBars["Optimize iPhone Storage"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()

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

    func testFilesAnalysisCanStartWithoutAnsweringStorageQuestions() {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-welcome"]
        app.launch()
        app.buttons["Analyze storage & cost"].tap()
        let files = app.buttons["Analyze selected files"]
        if !files.isHittable { app.swipeUp() }
        files.tap()
        XCTAssertTrue(app.navigationBars["Analyze selected files"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Choose files to analyze"].exists)
    }

    func testDuplicateRemovalNeedsSignOffAndSampleDataRemovesNothing() {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-welcome"]
        app.launch()
        app.buttons["Find duplicates"].tap()
        let samples = app.buttons["Explore sample results"]
        reveal(samples, in: app)
        XCTAssertTrue(samples.waitForExistence(timeout: 5))
        samples.tap()
        let review = app.buttons["Review duplicate groups"]
        reveal(review, in: app)
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        review.tap()
        XCTAssertTrue(app.navigationBars["Exact duplicates"].waitForExistence(timeout: 5))
        let delete = app.buttons["Delete 1 item from Apple Photos"]
        reveal(delete, in: app)
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertFalse(delete.isEnabled, "Removal must stay off until the user signs off.")
        let signOff = app.buttons["I understand and authorize these changes"]
        reveal(signOff, in: app)
        signOff.tap()
        XCTAssertTrue(delete.isEnabled)
        delete.tap()
        XCTAssertTrue(app.staticTexts["Sample data. Nothing was removed."].waitForExistence(timeout: 5))
        XCTAssertFalse(delete.isEnabled, "Each removal needs a fresh sign-off.")
    }

    func testArchiveTabOpensTheArchiveWorkflow() {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-welcome"]
        app.launch()
        app.tabBars.buttons["Archive"].tap()
        XCTAssertTrue(app.navigationBars["Archive originals"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Make an archive copy"].exists)
        let files = app.buttons["Pick files myself"]
        reveal(files, in: app)
        XCTAssertTrue(files.waitForExistence(timeout: 5))
    }

    func testArchivedAndLedgerTabsOpen() {
        let app = XCUIApplication()
        app.launchArguments += ["--skip-welcome"]
        app.launch()
        app.tabBars.buttons["Archived"].tap()
        XCTAssertTrue(app.navigationBars["Archived"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Ledger"].tap()
        XCTAssertTrue(app.navigationBars["Ledger"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Storage and cost analysis"].waitForExistence(timeout: 5))
    }

    func testFirstLaunchWelcomeLeadsToHome() {
        let app = XCUIApplication()
        app.launchArguments += ["--reset-welcome"]
        app.launch()
        let start = app.buttons["Get started"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Nothing is removed until you approve it."].exists)
        start.tap()
        XCTAssertTrue(app.navigationBars["TidyAway"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.tabBars.buttons["Archive"].exists)
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let list = app.collectionViews.firstMatch
        for _ in 0..<16 {
            if element.exists {
                let frame = element.frame
                if element.isHittable && frame.minY > 110 && frame.maxY < app.frame.maxY - 80 { return }
                if frame.minY < 110 {
                    list.swipeDown(velocity: .slow)
                    continue
                }
            }
            list.swipeUp(velocity: .slow)
        }
    }
}
