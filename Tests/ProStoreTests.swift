import StoreKitTest
import XCTest
@testable import SmartPhotoVault

/// Purchases are simulated with SKTestSession: a real `product.purchase()` needs a visible window
/// and hangs in a headless test run, so these tests drive the store's entitlement logic directly.
@MainActor
final class ProStoreTests: XCTestCase {
    private var session: SKTestSession!

    override func setUp() async throws {
        executionTimeAllowance = 60
        session = try SKTestSession(configurationFileNamed: "TidyAwayPro")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
    }

    override func tearDown() async throws {
        session.clearTransactions()
        session = nil
    }

    func testFreeArchiveAllowance() {
        XCTAssertEqual(ProStore.archiveAllowance(used: 0, selection: 1_000, unlocked: false), .fits(left: 5_000_000_000))
        XCTAssertEqual(ProStore.archiveAllowance(used: 4_000_000_000, selection: 2_000_000_000, unlocked: false),
                       .over(left: 1_000_000_000))
        XCTAssertEqual(ProStore.archiveAllowance(used: 6_000_000_000, selection: 1, unlocked: false), .over(left: 0))
        XCTAssertEqual(ProStore.archiveAllowance(used: 9_000_000_000, selection: 9_000_000_000, unlocked: true), .unlimited)
    }

    func testEntitlementFollowsPurchaseAndRefund() async throws {
        let store = ProStore()
        await store.refresh()
        XCTAssertFalse(store.unlocked, "Nothing is bought yet.")

        try session.buyProduct(productIdentifier: ProStore.productID)
        await store.refresh()
        XCTAssertTrue(store.unlocked, "A purchase on this Apple Account unlocks Pro, including on a new launch.")

        let transaction = try XCTUnwrap(session.allTransactions().first)
        try session.refundTransaction(identifier: transaction.identifier)
        await store.refresh()
        XCTAssertFalse(store.unlocked, "A refunded purchase no longer unlocks Pro.")
    }
}
