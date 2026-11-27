import Foundation
import XCTest
@testable import SmartPhotoVault

/// The 1.0.2 archive fixes approved on 27 Nov 2026 (A2, A3, B4, B5, D4, D12, skipping what is already
/// archived, Dropbox resume, and one name for getting items back).
final class Release102ArchiveTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 10_000)

    private func record(_ id: String, photo: String?, bytes: Int64 = 3, at seconds: TimeInterval = 10_000,
                        folder: Data? = nil, name: String = "IMG_1.HEIC") -> ArchivedRecord {
        ArchivedRecord(id: id, name: name, folderName: "Drive", bytes: bytes, digest: "d",
                       date: Date(timeIntervalSince1970: seconds), viaHomeServer: false, folderBookmark: folder, photoID: photo)
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    // MARK: - A2: the not-backed-up check confirms the copy is still there

    func testAnItemIsBackedUpOnlyWhileOneOfItsCopiesIsStillThere() async {
        let records = [record("gone", photo: "p1"), record("there", photo: "p1", at: 9_000), record("lost", photo: "p2")]
        let found = await BackupLedger.present(records) { $0.id == "there" }
        XCTAssertEqual(found, ["p1"], "p1 still has one copy; p2's only copy is gone, so it isn't backed up.")
    }

    func testADestinationThatDoesNotAnswerInTimeCountsAsNotBackedUp() async {
        let slow = await ArchiveDeadline.within(0.2) { () async throws -> Bool in
            try await Task.sleep(nanoseconds: 3_000_000_000)
            return true
        }
        XCTAssertNil(slow, "A check that takes too long is not an answer.")
        let quick = await ArchiveDeadline.within(2) { () async throws -> Bool in true }
        XCTAssertEqual(quick, true)
        let failing = await ArchiveDeadline.within(2) { () async throws -> Bool in throw ArchiveProofError.copyMissing }
        XCTAssertNil(failing)
        // Checks not started before the whole check's time is up count as not backed up.
        let none = await BackupLedger.present([record("a", photo: "p1")], deadline: 0) { _ in true }
        XCTAssertTrue(none.isEmpty)
    }

    func testAFolderCopyThatWasDeletedOrChangedSizeIsNotThere() async throws {
        let folder = try makeFolder()
        let file = folder.appendingPathComponent("IMG_1.HEIC")
        try Data([1, 2, 3]).write(to: file)
        let saved = record("r", photo: "p1", folder: try folder.bookmarkData())
        let wifi = ArchiveWiFi()
        let present = await ArchiveProver.copyStillThere(saved, wifi: wifi)
        XCTAssertTrue(present)
        XCTAssertEqual(try VerifiedArchive.presentSize(named: "IMG_1.HEIC", in: folder, wifi: nil), 3)
        try Data([1, 2, 3, 4]).write(to: file)
        let resized = await ArchiveProver.copyStillThere(saved, wifi: wifi)
        XCTAssertFalse(resized, "A copy that isn't the recorded size is not the copy.")
        try FileManager.default.removeItem(at: file)
        let gone = await ArchiveProver.copyStillThere(saved, wifi: wifi)
        XCTAssertFalse(gone)
        XCTAssertNil(try VerifiedArchive.presentSize(named: "IMG_1.HEIC", in: folder, wifi: nil))
        let noFolder = await ArchiveProver.copyStillThere(record("x", photo: "p1"), wifi: wifi)
        XCTAssertFalse(noFolder, "A record whose folder can't be found has no copy to count.")
    }
}
