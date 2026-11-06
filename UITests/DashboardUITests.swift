import XCTest

final class DashboardUITests: XCTestCase {
    func testAuthorizedLibraryScanReviewsRealResources() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["SmartPhotoVault"].waitForExistence(timeout: 15))
        let scan = app.buttons["Find exact duplicates"]
        for _ in 0..<8 {
            if scan.exists && scan.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        scan.tap()
        let review = app.buttons["Review duplicate groups"]
        for _ in 0..<12 {
            if review.exists && review.isHittable { break }
            app.swipeUp()
        }
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
        app.launch()
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
        XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 10))
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Denied photo permission"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate()
    }

    func testSampleDuplicateReview() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["SmartPhotoVault"].waitForExistence(timeout: 15))
        let samples = app.buttons["Explore sample results"]
        for _ in 0..<6 {
            if samples.exists && samples.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(samples.waitForExistence(timeout: 5))
        samples.tap()
        XCTAssertTrue(app.staticTexts["Sample data — not your photo library"].firstMatch.waitForExistence(timeout: 5))
        let review = app.buttons["Review duplicate groups"]
        for _ in 0..<8 {
            if review.exists && review.isHittable { break }
            app.swipeUp()
        }
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
}
