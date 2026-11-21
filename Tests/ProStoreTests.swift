import StoreKitTest
import XCTest
@testable import SmartPhotoVault

@MainActor
final class ProStoreTests: XCTestCase {
    private var session: SKTestSession!

    override func setUp() async throws {
        session = try SKTestSession(configurationFileNamed: "TidyAwayPro")
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.askToBuyEnabled = false
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

    func testPurchaseUnlocksAndRefundLocksAgain() async throws {
        let store = ProStore()
        await store.start()
        XCTAssertFalse(store.unlocked, "Nothing is bought yet.")
        XCTAssertNotNil(store.product, "The product loads from the StoreKit configuration.")
        await store.purchase()
        XCTAssertTrue(store.unlocked, "A verified purchase unlocks Pro right away.")

        let transaction = try XCTUnwrap(session.allTransactions().first)
        try session.refundTransaction(identifier: transaction.identifier)
        await store.refresh()
        XCTAssertFalse(store.unlocked, "A refunded purchase no longer unlocks Pro.")
    }

    func testRestoreFindsAnEarlierPurchase() async throws {
        let first = ProStore()
        await first.start()
        await first.purchase()
        XCTAssertTrue(first.unlocked)

        let second = ProStore()
        await second.start()
        XCTAssertTrue(second.unlocked, "A new launch sees the existing purchase.")
    }

    func testAskToBuyWaitsForApproval() async throws {
        session.askToBuyEnabled = true
        let store = ProStore()
        await store.start()
        await store.purchase()
        XCTAssertFalse(store.unlocked, "Pro stays locked while a parent decides.")
        XCTAssertEqual(store.notice, "Waiting for approval. Pro unlocks here as soon as it's approved.")

        let pending = try XCTUnwrap(session.allTransactions().first)
        try session.approveAskToBuyTransaction(identifier: pending.identifier)
        for _ in 0..<50 where !store.unlocked {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(store.unlocked, "Approval arrives through the launch-time update listener.")
    }
}
