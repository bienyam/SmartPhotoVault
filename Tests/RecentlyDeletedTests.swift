import XCTest
@testable import SmartPhotoVault

final class RecentlyDeletedTests: XCTestCase {
    func testOnlyTheLast30DaysCount() throws {
        let name = UUID().uuidString
        let store = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        XCTAssertEqual(RecentRemovals.bytes(now: now, store: store), 0)
        RecentRemovals.add(500, now: now.addingTimeInterval(-31 * 86_400), store: store)
        RecentRemovals.add(2_000, now: now.addingTimeInterval(-5 * 86_400), store: store)
        RecentRemovals.add(3_000, now: now, store: store)
        RecentRemovals.add(0, now: now, store: store)
        XCTAssertEqual(RecentRemovals.bytes(now: now, store: store), 5_000)
    }

    func testSmallOrNegativeChangesAreNotCalledAWin() {
        XCTAssertNil(SpaceGained.bytes(before: 10_000_000_000, after: 10_000_000_000))
        XCTAssertNil(SpaceGained.bytes(before: 10_000_000_000, after: 10_005_000_000))
        XCTAssertNil(SpaceGained.bytes(before: 10_000_000_000, after: 9_000_000_000))
        XCTAssertEqual(SpaceGained.bytes(before: 10_000_000_000, after: 13_000_000_000), 3_000_000_000)
    }
}
