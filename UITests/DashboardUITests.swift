import XCTest

final class DashboardUITests: XCTestCase {
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
