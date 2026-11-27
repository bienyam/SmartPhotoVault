import XCTest
@testable import SmartPhotoVault

/// The half sheet's pricing copy (App Review guideline 3.1.2): with a free trial, the amount billed
/// is in the button itself and leads the line under it.
final class ProSheetCopyTests: XCTestCase {
    func testTrialButtonCarriesTheBilledPrice() {
        let title = ProSheetCopy.button(trial: "7-day", price: "$24.99", unit: "year")
        XCTAssertEqual(title, "Try free, then $24.99/year")
        XCTAssertTrue(title.contains("$24.99"), "The billed amount must be on the button, not only the trial.")
    }

    func testTrialLineLeadsWithThePrice() {
        let line = ProSheetCopy.priceLine(trial: "7-day", price: "$24.99", unit: "year", loading: false)
        XCTAssertTrue(line.hasPrefix("$24.99 a year"), line)
        XCTAssertTrue(line.contains("7-day free trial"))
        XCTAssertTrue(line.contains("Cancel anytime in Settings."))
    }

    func testWithoutTrialTheButtonShowsThePrice() {
        XCTAssertEqual(ProSheetCopy.button(trial: nil, price: "$7.99", unit: "month"), "Get Pro · $7.99 a month")
        XCTAssertEqual(ProSheetCopy.priceLine(trial: nil, price: "$7.99", unit: "month", loading: false),
                       "Renews each month until you cancel. Cancel anytime in Settings.")
    }

    func testWithoutAPriceNothingIsPromised() {
        XCTAssertEqual(ProSheetCopy.button(trial: nil, price: nil, unit: "year"), "Get TidyAway Pro")
        XCTAssertEqual(ProSheetCopy.priceLine(trial: nil, price: nil, unit: "year", loading: true),
                       "Getting the price from the App Store…")
        XCTAssertEqual(ProSheetCopy.priceLine(trial: nil, price: nil, unit: "year", loading: false),
                       "The price is shown by the App Store before you pay.")
    }
}
