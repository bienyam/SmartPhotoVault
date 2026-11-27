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

    // MARK: Re-checking entitlements

    /// Apple's entitlement list decides on its own: a subscription in the billing grace period is
    /// listed (and keeps Pro) even though its expiry date has passed; no date is checked here.
    func testEntitledProductsDecideThePlan() {
        XCTAssertEqual(ProStore.plan(entitled: []), .none)
        XCTAssertEqual(ProStore.plan(entitled: [ProStore.monthlyID]), .monthly)
        XCTAssertEqual(ProStore.plan(entitled: [ProStore.yearlyID]), .yearly)
        XCTAssertEqual(ProStore.plan(entitled: ["com.example.other"]), .none)
    }

    func testLifetimeWinsOverAnEntitledSubscription() {
        XCTAssertEqual(ProStore.plan(entitled: [ProStore.monthlyID, ProStore.lifetimeID]), .lifetime)
        XCTAssertEqual(ProStore.plan(entitled: [ProStore.lifetimeID, ProStore.yearlyID]), .lifetime)
    }

    func testRecheckRightAfterAPurchaseNeverTakesProAway() {
        let now = Date()
        let justNow = now.addingTimeInterval(-2)
        XCTAssertEqual(ProStore.plan(refreshed: .none, current: .monthly, purchasedAt: justNow, now: now), .monthly)
        XCTAssertEqual(ProStore.plan(refreshed: .monthly, current: .lifetime, purchasedAt: justNow, now: now), .lifetime)
        // A re-check that finds more than was bought still wins.
        XCTAssertEqual(ProStore.plan(refreshed: .lifetime, current: .monthly, purchasedAt: justNow, now: now), .lifetime)
    }

    func testRecheckDecidesOnceThePurchaseIsNoLongerFresh() {
        let now = Date()
        let earlier = now.addingTimeInterval(-(ProStore.purchaseGrace + 1))
        XCTAssertEqual(ProStore.plan(refreshed: .none, current: .monthly, purchasedAt: earlier, now: now), .none)
        XCTAssertEqual(ProStore.plan(refreshed: .none, current: .yearly, purchasedAt: nil, now: now), .none)
        XCTAssertEqual(ProStore.plan(refreshed: .monthly, current: .none, purchasedAt: nil, now: now), .monthly)
    }

    // MARK: Tester access fails closed

    func testTesterAccessUnlocksOnlyInTheTestEnvironment() {
        XCTAssertTrue(ProStore.testerUnlocks(in: .sandbox))
        XCTAssertTrue(ProStore.testerUnlocks(in: .xcode))
        XCTAssertFalse(ProStore.testerUnlocks(in: .production))
        // Apple's record couldn't be read: nothing unlocks.
        XCTAssertFalse(ProStore.testerUnlocks(in: nil))
    }
}
