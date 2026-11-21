import XCTest
@testable import SmartPhotoVault

/// The purchase itself is tested with a sandbox account on a real iPhone (PHONE_TEST_CHECKLIST.md):
/// StoreKit calls hang in the headless CI simulator, so these tests cover the free allowance only.
final class ProStoreTests: XCTestCase {
    func testFreeArchiveAllowance() {
        XCTAssertEqual(ProStore.archiveAllowance(used: 0, selection: 1_000, unlocked: false), .fits(left: 5_000_000_000))
        XCTAssertEqual(ProStore.archiveAllowance(used: 4_000_000_000, selection: 2_000_000_000, unlocked: false),
                       .over(left: 1_000_000_000))
        XCTAssertEqual(ProStore.archiveAllowance(used: 6_000_000_000, selection: 1, unlocked: false), .over(left: 0))
        XCTAssertEqual(ProStore.archiveAllowance(used: 9_000_000_000, selection: 9_000_000_000, unlocked: true), .unlimited)
    }
}
