import XCTest
@testable import SmartPhotoVault

final class ArchivedRecordTests: XCTestCase {
    private func record(_ name: String, at seconds: TimeInterval) -> ArchivedRecord {
        ArchivedRecord(id: UUID().uuidString, name: name, folderName: "Archive", bytes: 1_234, digest: "abc",
                       date: Date(timeIntervalSince1970: seconds), viaHomeServer: false, folderBookmark: Data([1, 2, 3]))
    }

    func testArchivedRecordsRoundTripNewestFirst() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try InventoryStore(url: path)
        XCTAssertTrue(try store.archived().isEmpty)
        let older = record("Older.heic", at: 1_000)
        let newer = record("Newer ' 📷.jpg", at: 2_000)
        try store.saveArchived([older, newer])
        XCTAssertEqual(try store.archived(), [newer, older])
        let reopened = try InventoryStore(url: path)
        XCTAssertEqual(try reopened.archived().map(\.name), ["Newer ' 📷.jpg", "Older.heic"])
        XCTAssertEqual(try reopened.archived().first?.folderBookmark, Data([1, 2, 3]))
    }
}
