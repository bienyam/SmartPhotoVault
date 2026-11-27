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

    // MARK: - A3: local copies are read back in full once before removal

    func testAReadBackCopyStaysSizeOnlyUntilItChanges() throws {
        let store = try XCTUnwrap(UserDefaults(suiteName: "readback-\(UUID().uuidString)"))
        let saved = record("r", photo: "p1")
        let stamp = CopyStamp(bytes: 3, modified: date, checksum: nil)
        XCTAssertFalse(ReadBackLedger.readBack(saved, stamp: stamp, store: store), "Never read back: read it in full.")
        ReadBackLedger.note(saved, stamp: stamp, store: store)
        XCTAssertTrue(ReadBackLedger.readBack(saved, stamp: stamp, store: store))
        XCTAssertFalse(ReadBackLedger.readBack(saved, stamp: CopyStamp(bytes: 3, modified: date.addingTimeInterval(1), checksum: nil), store: store),
                       "A copy changed since it was read back is read back again.")
        XCTAssertFalse(ReadBackLedger.readBack(saved, stamp: CopyStamp(bytes: 3, modified: nil, checksum: nil), store: store),
                       "Without a modification date a change can't be seen, so it is always read back.")
        XCTAssertFalse(ReadBackLedger.readBack(record("other", photo: "p1"), stamp: stamp, store: store))
        let key = try XCTUnwrap((store.dictionary(forKey: ReadBackLedger.key) as? [String: String])?.keys.first)
        XCTAssertFalse(key.contains("IMG_1"), "No file names are kept.")
    }

    // MARK: - B4: the free 5 GB counts every item and is kept to during the run

    func testTheFreeAllowanceIsKeptToItemByItem() {
        var budget = FreeArchiveBudget(used: 4_000, unlimited: false, limit: 5_000)
        XCTAssertEqual(budget.left, 1_000)
        XCTAssertTrue(budget.take(600))
        XCTAssertFalse(budget.take(600), "The next item would pass the free limit, so it isn't copied.")
        XCTAssertFalse(budget.take(nil), "On a free plan an item of unknown size isn't copied.")
        XCTAssertTrue(budget.take(400))
        budget.giveBack(400)
        XCTAssertEqual(budget.left, 400, "A failed copy gives its room back.")
        budget.settle(took: 600, actual: 900)
        XCTAssertEqual(budget.left, 100, "The real size replaces the estimate once copied.")
        XCTAssertEqual(FreeArchiveBudget(used: 9_000, unlimited: false, limit: 5_000).left, 0)

        var pro = FreeArchiveBudget(used: 9_000, unlimited: true, limit: 5_000)
        XCTAssertNil(pro.left)
        XCTAssertTrue(pro.take(nil), "Pro has no limit.")
        XCTAssertTrue(pro.take(1_000_000))
    }

    @MainActor func testAnItemOverTheFreeLimitSaysWhy() {
        XCTAssertEqual(ArchiveRun.reason(for: OverFreeArchive()), "Over the free 5 GB of archiving")
        XCTAssertEqual(OverFreeArchive().localizedDescription,
                       "It doesn't fit in what is left of your free 5 GB of archiving. Archiving more needs TidyAway Pro.")
        XCTAssertTrue(FreeArchiveBudget.reportedSizes([]).isEmpty)
    }

    // MARK: - B5: Copy first says when the free 5 GB can't hold the selection

    private func photo(_ id: String, bytes: Int64) -> AssetRecord {
        AssetRecord(id: id, filename: "\(id).mov", mediaType: 2, favorite: false, createdAt: date,
                    resources: [], issue: "Original resource is not available locally.",
                    isScreenshot: false, albumIDs: [], cloudBytes: bytes)
    }

    func testTheNotBackedUpAlertSaysWhenTheFreeAllowanceCannotHoldThem() throws {
        var check = try XCTUnwrap(BackupCheck.alert(for: .list, selected: [photo("a", bytes: 3_000)], archived: []))
        XCTAssertTrue(check.copyFits, "Pro, or nothing known: no limit line.")
        XCTAssertNil(check.allowanceLine)
        check.freeLeft = 5_000
        XCTAssertTrue(check.copyFits)
        XCTAssertNil(check.allowanceLine)
        check.freeLeft = 0
        XCTAssertFalse(check.copyFits)
        XCTAssertEqual(check.allowanceLine, "Your free 5 GB of archiving is used. Archiving more needs TidyAway Pro.")
        check.freeLeft = 1_000
        XCTAssertFalse(check.copyFits)
        XCTAssertTrue(check.allowanceLine?.hasPrefix("Only ") == true)
        XCTAssertTrue(check.allowanceLine?.hasSuffix("Archiving more needs TidyAway Pro.") == true)
    }

    // MARK: - Skipping what is already archived in the same place

    func testOnlyARecordForTheSameFolderCountsAsAlreadyArchivedHere() throws {
        let here = try makeFolder()
        let elsewhere = try makeFolder()
        let saved = record("r", photo: "p1", folder: try here.bookmarkData())
        XCTAssertTrue(AlreadyArchivedHere.inFolder(saved, here.resolvingSymlinksInPath().standardizedFileURL.path))
        XCTAssertFalse(AlreadyArchivedHere.inFolder(saved, elsewhere.resolvingSymlinksInPath().standardizedFileURL.path),
                       "A copy in another folder doesn't stop a copy to this one.")
        var drive = saved
        drive.driveFileID = "g1"
        XCTAssertFalse(AlreadyArchivedHere.inFolder(drive, here.standardizedFileURL.path), "A Google Drive record is never a folder record.")
        XCTAssertFalse(AlreadyArchivedHere.inFolder(record("x", photo: "p1"), here.standardizedFileURL.path))
    }

    func testAnEditedPhotoIsNeverSkippedAsAlreadyArchived() {
        // The same rule as the not-backed-up check: changed in Photos since the copy, so copy it again.
        let saved = record("r", photo: "p1")
        let edited = ["p1": OriginalNow(single: true, parts: nil, modified: saved.date.addingTimeInterval(60))]
        XCTAssertTrue(BackupLedger.covering([saved], now: edited).isEmpty)
        let same = ["p1": OriginalNow(single: true, parts: nil, modified: saved.date.addingTimeInterval(-60))]
        XCTAssertEqual(BackupLedger.covering([saved], now: same).map(\.id), ["r"])
        var waiting = saved
        waiting.unflushed = true
        XCTAssertTrue(BackupLedger.covering([waiting], now: same).isEmpty, "An unconfirmed copy is never enough to skip.")
    }

    func testTheRunSummaryCountsItemsAlreadyArchivedHere() {
        let outcome = ArchiveOutcome(completion: nil, failures: [], left: 0, place: "Drive", alreadyHere: 3)
        XCTAssertEqual(outcome.alreadyHere, 3)
        XCTAssertEqual(ArchiveOutcome(completion: nil, failures: [], left: 0, place: "Drive").alreadyHere, 0)
    }

    // MARK: - D5 follow-up: Dropbox uploads resume

    private func incorrectOffset(_ offset: Int64, nested: Bool = false) -> Data {
        let inner = #"{".tag":"incorrect_offset","correct_offset":\#(offset)}"#
        let error = nested ? #"{".tag":"lookup_failed","lookup_failed":\#(inner)}"# : inner
        return Data(#"{"error_summary":"incorrect_offset/..","error":\#(error)}"#.utf8)
    }

    func testDropboxSaysWhichOffsetItWants() {
        XCTAssertEqual(UploadRetry.dropboxCorrectOffset(incorrectOffset(4_194_304)), 4_194_304)
        XCTAssertEqual(UploadRetry.dropboxCorrectOffset(incorrectOffset(77, nested: true)), 77)
        XCTAssertNil(UploadRetry.dropboxCorrectOffset(Data(#"{"error":{".tag":"closed"}}"#.utf8)))
        XCTAssertNil(UploadRetry.dropboxCorrectOffset(Data("not json".utf8)))
    }

    func testADropboxPieceCarriesOnFromTheOffsetDropboxGives() throws {
        let piece = Data(repeating: 1, count: 100)
        var sent: [(Int64, Int)] = []
        var answers: [(status: Int, body: Data)] = [(409, incorrectOffset(1_060)), (200, Data())]
        try CloudStream.dropboxPiece(piece, at: 1_000, pause: { _ in }) { at, rest in
            sent.append((at, rest.count))
            return answers.removeFirst()
        }
        XCTAssertEqual(sent.map(\.0), [1_000, 1_060], "Only what Dropbox doesn't have yet is sent again.")
        XCTAssertEqual(sent.map(\.1), [100, 40])
    }

    func testADropboxPieceRetriesADropAndStopsAfterAFewTries() throws {
        let piece = Data(repeating: 1, count: 10)
        var calls = 0
        try CloudStream.dropboxPiece(piece, at: 0, pause: { _ in }) { _, _ in
            calls += 1
            if calls == 1 { throw URLError(.networkConnectionLost) }
            return (409, self.incorrectOffset(10))
        }
        XCTAssertEqual(calls, 2, "After the drop, Dropbox already had the whole piece.")

        var busy = 0
        XCTAssertThrowsError(try CloudStream.dropboxPiece(piece, at: 0, pause: { _ in }) { _, _ in
            busy += 1
            return (503, Data())
        })
        XCTAssertEqual(busy, UploadRetry.attempts + 1, "A busy server is tried a few times, then the item fails.")
        XCTAssertThrowsError(try CloudStream.dropboxPiece(piece, at: 0, pause: { _ in }) { _, _ in (409, self.incorrectOffset(500)) },
                             "An offset past this piece can't be right.")
        XCTAssertThrowsError(try CloudStream.dropboxPiece(piece, at: 0, pause: { _ in }) { _, _ in (400, Data()) })
    }

    // MARK: - D4: Get back restores date, place, albums and favorite

    func testANewRecordKeepsHowThePhotoWasAndAnOldOneRestoresAsBefore() throws {
        let details = PhotoDetails(created: Date(timeIntervalSince1970: 1_600_000_000), latitude: 51.5007, longitude: -0.1246,
                                   albums: ["album-1", "album-2"], favorite: true)
        let saved = record("r", photo: "p1").remembering(details)
        XCTAssertEqual(saved.details, details)
        let back = try JSONDecoder().decode(ArchivedRecord.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(back, saved, "The details survive the archive list.")
        XCTAssertEqual(back.albumIDs, ["album-1", "album-2"])
        XCTAssertEqual(back.favorite, true)

        let json = #"{"id":"r1","name":"IMG_1.HEIC","folderName":"Drive","bytes":10,"digest":"d","date":0,"viaHomeServer":false,"photoID":"p1"}"#
        let old = try JSONDecoder().decode(ArchivedRecord.self, from: Data(json.utf8))
        XCTAssertNil(old.details, "A record saved before 1.0.2 has no details and comes back as it always did.")
        XCTAssertEqual(record("x", photo: nil).remembering(nil), record("x", photo: nil))

        let noAlbums = record("y", photo: "p2").remembering(PhotoDetails(created: nil, latitude: nil, longitude: nil, albums: [], favorite: false))
        XCTAssertNil(noAlbums.albumIDs)
        XCTAssertEqual(noAlbums.favorite, false)
        XCTAssertEqual(noAlbums.files.count, 1)
        XCTAssertEqual(noAlbums.confirming.favorite, false, "Confirming a copy keeps its details.")
    }

    // MARK: - D12: the first check says what it checks

    @MainActor func testTheFirstCheckSaysSameSizeNotByteForByte() {
        XCTAssertEqual(ArchivedRemovalView.copiedTitle, "Copied, same size as the original")
        XCTAssertFalse(ArchivedRemovalView.copiedTitle.contains("byte for byte"))
    }

    func testAFullReadBackReportsProgressAndCatchesChangedBytes() throws {
        let folder = try makeFolder()
        let bytes = Data(repeating: 0x2a, count: 700_000)
        let source = try makeFolder().appendingPathComponent("IMG_9.MOV")
        try bytes.write(to: source)
        let receipt = try VerifiedArchive.copy(ArchiveItem(id: "a", name: "IMG_9.MOV", source: .file(source)), to: folder)
        let progress = ProofProgress()
        _ = try VerifiedArchive.checkCopy(named: "IMG_9.MOV", in: folder, expected: receipt.fingerprint, wifi: nil,
                                          offDevice: false, read: { progress.add($0) })
        XCTAssertEqual(progress.bytes, Int64(bytes.count), "Progress hears every byte read back.")
        var changed = bytes
        changed[10] = 0
        try changed.write(to: receipt.url)
        XCTAssertThrowsError(try VerifiedArchive.checkCopy(named: "IMG_9.MOV", in: folder, expected: receipt.fingerprint,
                                                           wifi: nil, offDevice: false),
                             "Same size, different bytes: only the full read-back sees it.")
    }
}
