import XCTest
@testable import SmartPhotoVault

final class PhotoInventoryTests: XCTestCase {
    func testFavoritesDoNotAddExtraAssetsToTotal() {
        let inventory = PhotoInventory(photos: 12, videos: 3, favorites: 5)
        XCTAssertEqual(inventory.total, 15)
    }

    func testOlderScanRecordHasUnknownScreenshotStatus() throws {
        let data = Data("""
        {"id":"asset","filename":"IMG.png","mediaType":1,"favorite":false,"resources":[]}
        """.utf8)
        let record = try JSONDecoder().decode(AssetRecord.self, from: data)
        XCTAssertNil(record.isScreenshot)
    }
}

