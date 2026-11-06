import XCTest
import Photos
@testable import SmartPhotoVault

final class DashboardLifecycleTests: XCTestCase {
    @MainActor
    func testReturningWithUnchangedFullAccessKeepsCompletedCounts() {
        let model = DashboardModel()
        XCTAssertEqual(model.authorization, .authorized, "CI grants full access through the consent UI first.")
        guard model.authorization == .authorized else { return }
        let completed = PhotoInventory(photos: 25, videos: 4, favorites: 2)
        model.inventory = completed
        model.refreshAuthorization()
        XCTAssertEqual(model.inventory, completed, "Returning from a permission sheet or another app must not erase completed counts.")
    }
}
