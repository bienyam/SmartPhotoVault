import XCTest
@testable import SmartPhotoVault

@MainActor
final class ProPlanTests: XCTestCase {
    func testEachPurchaseLeadsToItsPlan() {
        XCTAssertEqual(ProStore.plan(after: ProStore.monthlyID, current: .none), .monthly)
        XCTAssertEqual(ProStore.plan(after: ProStore.yearlyID, current: .none), .yearly)
        XCTAssertEqual(ProStore.plan(after: ProStore.lifetimeID, current: .monthly), .lifetime)
    }

    func testLifetimeIsNeverDowngraded() {
        XCTAssertEqual(ProStore.plan(after: ProStore.monthlyID, current: .lifetime), .lifetime)
        XCTAssertEqual(ProStore.plan(after: ProStore.yearlyID, current: .lifetime), .lifetime)
    }

    func testYearlyIsASubscriptionProduct() {
        XCTAssertTrue(ProStore.subscriptionIDs.contains(ProStore.yearlyID))
        XCTAssertTrue(ProStore.productIDs.isSuperset(of: [ProStore.monthlyID, ProStore.yearlyID, ProStore.lifetimeID]))
    }

    func testTrialLengthReadsNaturally() {
        XCTAssertEqual(ProStore.trialLength(3, .day), "3 days")
        XCTAssertEqual(ProStore.trialLength(1, .week), "1 week")
    }
}
