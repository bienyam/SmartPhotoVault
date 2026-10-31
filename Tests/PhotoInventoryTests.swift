import XCTest
@testable import SmartPhotoVault

final class PhotoInventoryTests: XCTestCase {
    func testFavoritesDoNotAddExtraAssetsToTotal() {
        let inventory = PhotoInventory(photos: 12, videos: 3, favorites: 5)
        XCTAssertEqual(inventory.total, 15)
    }
}

