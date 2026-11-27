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
        XCTAssertEqual(try reopened.archivedBytes(), 2_468)
    }

    func testLargeArchivesKeepEveryRecordAndTheFullTotal() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try InventoryStore(url: path)
        XCTAssertEqual(try store.archivedBytes(), 0)
        try store.saveArchived((0..<2_105).map { record("\($0).heic", at: TimeInterval($0)) })
        XCTAssertEqual(try store.archived().count, 2_105)
        XCTAssertEqual(try store.archived().last?.name, "0.heic", "The oldest copy stays reachable.")
        XCTAssertEqual(try store.archivedBytes(), 2_105 * 1_234)
    }

    // MARK: - A copy the drive hasn't confirmed (1.0.2, A1)

    func testRecordsSavedBeforeThisDecodeAsConfirmed() throws {
        let json = #"{"id":"r1","name":"IMG_1.HEIC","folderName":"Drive","bytes":10,"digest":"d","date":0,"viaHomeServer":false,"photoID":"p1"}"#
        let old = try JSONDecoder().decode(ArchivedRecord.self, from: Data(json.utf8))
        XCTAssertNil(old.unflushed)
        XCTAssertTrue(old.confirmed, "Every record saved before 1.0.2 keeps counting exactly as it did.")
    }

    func testAnUnconfirmedCopyIsSavedAndPromotedInPlace() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try InventoryStore(url: path)
        var waiting = record("IMG_2.HEIC", at: 1_000)
        waiting.unflushed = true
        XCTAssertFalse(waiting.confirmed)
        try store.saveArchived([waiting])
        let back = try XCTUnwrap(try InventoryStore(url: path).archived().first)
        XCTAssertEqual(back.unflushed, true, "It stays unconfirmed when the app is closed before the drive confirms.")
        XCTAssertEqual(try store.archivedCount(), 1, "It is still listed in Get back.")
        XCTAssertEqual(try store.archivedBytes(), 1_234, "It still counts toward the free 5 GB.")

        try store.saveArchived([back.confirming])
        let promoted = try store.archived()
        XCTAssertEqual(promoted.count, 1, "Confirming replaces the record rather than adding one.")
        XCTAssertTrue(try XCTUnwrap(promoted.first).confirmed)
        XCTAssertEqual(promoted.first?.id, waiting.id)
    }

    func testAnUnconfirmedCopyIsNeverABackupOrSafeToRemove() {
        let date = Date(timeIntervalSince1970: 1_000)
        var waiting = ArchivedRecord(id: "w", name: "IMG_3.HEIC", folderName: "Drive", bytes: 10, digest: "d", date: date,
                                     viaHomeServer: false, folderBookmark: nil, photoID: "p1")
        waiting.unflushed = true
        let confirmed = ArchivedRecord(id: "c", name: "IMG_4.HEIC", folderName: "Drive", bytes: 10, digest: "d", date: date,
                                       viaHomeServer: false, folderBookmark: nil, photoID: "p2")
        let photos = ["p1": OriginalNow(single: true, parts: nil, modified: date.addingTimeInterval(-60)),
                      "p2": OriginalNow(single: true, parts: nil, modified: date.addingTimeInterval(-60))]
        XCTAssertEqual(BackupLedger.photoIDs(in: [waiting, confirmed], now: photos), ["p2"],
                       "Not backed up until the drive confirms it saved the copy.")
        XCTAssertEqual(BackupLedger.photoIDs(in: [waiting.confirming], now: photos), ["p1"])

        let places = ArchivedOnPhone.places(records: [waiting, confirmed], onPhone: ["p1", "p2"])
        XCTAssertEqual(places.flatMap { $0.records.map(\.id) }, ["c"], "Already archived never offers an unconfirmed copy for removal.")
        XCTAssertTrue(ArchivedOnPhone.places(records: [waiting], onPhone: ["p1"]).isEmpty)
    }
}
