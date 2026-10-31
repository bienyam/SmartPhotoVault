import XCTest

final class DashboardUITests: XCTestCase {
    func testSampleDuplicateReview() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.navigationBars["SmartPhotoVault"].waitForExistence(timeout: 15))
        let review = app.buttons["Review duplicate groups"]
        for _ in 0..<8 {
            if review.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(review.waitForExistence(timeout: 5))
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
