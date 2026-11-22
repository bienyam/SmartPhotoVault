import XCTest
@testable import SmartPhotoVault

final class ArchiveGroupingTests: XCTestCase {
    private func record(_ name: String, _ date: Date, place: String = "Google Drive", bytes: Int64 = 10) -> ArchivedRecord {
        ArchivedRecord(id: UUID().uuidString, name: name, folderName: place, bytes: bytes, digest: "ab", date: date,
                       viaHomeServer: false, folderBookmark: nil)
    }

    func testArchivedItemsGroupByDayNewestFirst() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let monday = Date(timeIntervalSince1970: 1_700_000_000)
        let mondayLater = monday.addingTimeInterval(3_600)
        let tuesday = monday.addingTimeInterval(86_400)
        let days = ArchiveDay.group([record("b.jpg", monday), record("a.jpg", mondayLater, place: "USB drive"),
                                     record("c.mov", tuesday, bytes: 30)], calendar: calendar)
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[0].records.map(\.name), ["c.mov"], "Newest day first.")
        XCTAssertEqual(days[1].records.map(\.name), ["a.jpg", "b.jpg"], "Files within a day in name order.")
        XCTAssertEqual(days[1].bytes, 20)
        XCTAssertEqual(days[1].places, "Google Drive, USB drive")
    }

    func testOnlyPhotosLibraryItemsCanBeRemovedAfterArchiving() {
        let done = ArchiveCompletion(items: [
            ArchiveItem(id: "1", name: "a.heic", source: .photo("photo-1", expected: nil)),
            ArchiveItem(id: "2", name: "b.pdf", source: .file(URL(fileURLWithPath: "/tmp/b.pdf")))
        ], bytes: 100, place: "Google Drive", driveFolderID: "folder")
        XCTAssertEqual(done.photoIDs, ["photo-1"], "Files picked from Files are never removed.")
        XCTAssertEqual(done.count, 2)
    }

    func testDeleteSizeCountsOnlyTheGivenItemsWithSavedCopies() {
        let photo = ArchiveItem(id: "1", name: "a.heic", source: .photo("photo-1", expected: nil))
        let other = ArchiveItem(id: "2", name: "a.heic", source: .photo("photo-2", expected: nil))
        let done = ArchiveCompletion(items: [photo, other], bytes: 100, place: "Drive", driveFolderID: nil,
                                     copies: ["1": record("a.heic", Date(), bytes: 40)])
        XCTAssertEqual(done.bytes(of: [photo]), 40)
        XCTAssertEqual(done.bytes(of: [photo, other]), 40, "No saved copy, so it isn't counted, even with the same name.")
    }

    func testRemovalAfterArchiveIsSwitchedOnByTheOwner() {
        XCTAssertTrue(RemovalAfterArchive.enabled, "Switched on by the owner on 2026-11-21.")
    }

    func testVideosAreRecognisedForPuttingBackIntoPhotos() {
        XCTAssertTrue(ArchivedDayView.isVideo("Clip.MOV"))
        XCTAssertTrue(ArchivedDayView.isVideo("clip.mp4"))
        XCTAssertFalse(ArchivedDayView.isVideo("IMG_1.HEIC"))
    }
}
