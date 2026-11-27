import Foundation
import XCTest
@testable import SmartPhotoVault

final class VerifiedArchiveTests: XCTestCase {
    func testCapacityComparisonUsesOnlyKnownAvailableSpace() {
        XCTAssertNil(ArchiveCapacity(selected: 100, available: nil).fits)
        XCTAssertEqual(ArchiveCapacity(selected: 100, available: 100).fits, true)
        XCTAssertEqual(ArchiveCapacity(selected: 100, available: 99).fits, false)
    }

    func testCopyAndRestorePreserveSourceAndRejectAnOverwrite() throws {
        try withFolders { source, archive, restore in
            let bytes = Data(repeating: 0x7f, count: 600_000)
            try bytes.write(to: source)
            let item = ArchiveItem(id: "test", name: source.lastPathComponent, source: .file(source))

            let receipt = try VerifiedArchive.copy(item, to: archive)
            XCTAssertEqual(receipt.fingerprint.bytes, Int64(bytes.count))
            XCTAssertEqual(try Data(contentsOf: receipt.url), bytes)
            XCTAssertThrowsError(try VerifiedArchive.copy(item, to: archive))
            XCTAssertEqual(try Data(contentsOf: VerifiedArchive.restore(receipt, to: restore)), bytes)
            XCTAssertEqual(try Data(contentsOf: source), bytes)
            XCTAssertEqual(try Data(contentsOf: receipt.url), bytes)
        }
    }

    func testRestoreRejectsChangedArchiveAndLeavesNoPartialFile() throws {
        try withFolders { source, archive, restore in
            try Data([1, 2, 3]).write(to: source)
            let item = ArchiveItem(id: "test", name: source.lastPathComponent, source: .file(source))
            let receipt = try VerifiedArchive.copy(item, to: archive)
            try Data([1, 2, 4]).write(to: receipt.url)

            XCTAssertThrowsError(try VerifiedArchive.restore(receipt, to: restore))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: restore.path), [])
            XCTAssertEqual(try Data(contentsOf: source), Data([1, 2, 3]))
        }
    }

    func testCopyMustStillMatchInFullBeforeItsOriginalMayGo() throws {
        try withFolders { source, archive, _ in
            let bytes = Data(repeating: 0x5a, count: 700_000)
            try bytes.write(to: source)
            let item = ArchiveItem(id: "test", name: source.lastPathComponent, source: .file(source))
            let receipt = try VerifiedArchive.copy(item, to: archive)
            let name = receipt.url.lastPathComponent
            func check() throws -> CopyStamp {
                try VerifiedArchive.checkCopy(named: name, in: archive, expected: receipt.fingerprint, wifi: nil, offDevice: false)
            }
            let stamp = try check()
            XCTAssertEqual(stamp.bytes, 700_000)
            XCTAssertEqual(try VerifiedArchive.copyStamp(named: name, in: archive, wifi: nil, offDevice: false), stamp)

            var tampered = bytes
            tampered[650_000] ^= 0xff
            try tampered.write(to: receipt.url)
            XCTAssertThrowsError(try check(), "Same size, one byte different.") {
                XCTAssertEqual($0 as? ArchiveProofError, .copyDiffers)
            }
            try bytes.dropLast().write(to: receipt.url)
            XCTAssertThrowsError(try check(), "Cut short.") { XCTAssertEqual($0 as? ArchiveProofError, .copyDiffers) }
            try FileManager.default.removeItem(at: receipt.url)
            XCTAssertThrowsError(try check(), "Gone.")
            XCTAssertThrowsError(try VerifiedArchive.copyStamp(named: name, in: archive, wifi: nil, offDevice: false))
        }
    }

    /// Owner, 2026-11-22: the copy is confirmed by its size on the destination, to the byte.
    func testCopyIsConfirmedByItsExactSizeOnTheDestination() throws {
        try withFolders { source, archive, _ in
            try Data(repeating: 7, count: 123_457).write(to: source)
            let item = ArchiveItem(id: "test", name: source.lastPathComponent, source: .file(source))
            let receipt = try VerifiedArchive.copy(item, to: archive)
            XCTAssertEqual(receipt.fingerprint.bytes, 123_457)
            XCTAssertEqual(try VerifiedArchive.storedSize(of: receipt.url), 123_457)
            try Data(repeating: 7, count: 123_456).write(to: receipt.url)
            XCTAssertEqual(try VerifiedArchive.storedSize(of: receipt.url), 123_456, "One byte short shows.")
        }
    }

    func testABatchCopiesWithoutFlushingEachFileThenFlushesOnce() throws {
        try withFolders { source, archive, _ in
            try Data(repeating: 9, count: 50_000).write(to: source)
            let item = ArchiveItem(id: "test", name: source.lastPathComponent, source: .file(source))
            let receipt = try VerifiedArchive.copy(item, to: archive, flush: false)
            XCTAssertEqual(try VerifiedArchive.storedSize(of: receipt.url), 50_000)
            XCTAssertNoThrow(try VerifiedArchive.flushDrive(receipt.url, in: archive))
            XCTAssertThrowsError(try VerifiedArchive.flushDrive(archive.appendingPathComponent("gone"), in: archive))
        }
    }

    func testChangedCopyNoLongerMatchesItsStamp() throws {
        try withFolders { source, archive, _ in
            try Data([1, 2, 3]).write(to: source)
            let item = ArchiveItem(id: "test", name: source.lastPathComponent, source: .file(source))
            let receipt = try VerifiedArchive.copy(item, to: archive)
            let name = receipt.url.lastPathComponent
            let stamp = try VerifiedArchive.checkCopy(named: name, in: archive, expected: receipt.fingerprint, wifi: nil, offDevice: false)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 5)], ofItemAtPath: receipt.url.path)
            XCTAssertNotEqual(try VerifiedArchive.copyStamp(named: name, in: archive, wifi: nil, offDevice: false), stamp)
        }
    }

    /// Owner's rule: no delete unless the destination copy can be confirmed. A folder on the iPhone (or a
    /// cloud app's folder, which is also on the iPhone until it uploads) never counts.
    func testCopyOnTheIPhoneItselfNeverAllowsDeleting() throws {
        try withFolders { source, archive, _ in
            try Data([1, 2, 3]).write(to: source)
            let item = ArchiveItem(id: "test", name: source.lastPathComponent, source: .file(source))
            let receipt = try VerifiedArchive.copy(item, to: archive)
            let name = receipt.url.lastPathComponent
            XCTAssertThrowsError(try VerifiedArchive.checkCopy(named: name, in: archive, expected: receipt.fingerprint, wifi: nil)) {
                XCTAssertEqual($0 as? ArchiveProofError, .notConfirmable)
            }
            XCTAssertThrowsError(try VerifiedArchive.copyStamp(named: name, in: archive, wifi: nil)) {
                XCTAssertEqual($0 as? ArchiveProofError, .notConfirmable)
            }
        }
    }

    func testGoogleDriveCopyMustExistAndMatchSizeAndChecksum() throws {
        let record = ArchivedRecord(id: "r", name: "a.heic", folderName: "Google Drive", bytes: 10, digest: "ab12",
                                    date: Date(), viaHomeServer: false, folderBookmark: nil, driveFileID: "f")
        func stored(size: String? = "10", sha: String? = "AB12", trashed: Bool? = false) -> GoogleDriveClient.StoredFile {
            GoogleDriveClient.StoredFile(id: "f", size: size, sha256Checksum: sha, md5Checksum: nil, trashed: trashed)
        }
        XCTAssertNoThrow(try ArchiveProver.stamp(of: stored(), for: record))
        XCTAssertThrowsError(try ArchiveProver.stamp(of: stored(size: "9"), for: record))
        XCTAssertThrowsError(try ArchiveProver.stamp(of: stored(size: nil), for: record))
        XCTAssertThrowsError(try ArchiveProver.stamp(of: stored(sha: "ffff"), for: record))
        XCTAssertThrowsError(try ArchiveProver.stamp(of: stored(trashed: true), for: record))
        XCTAssertThrowsError(try ArchiveProver.stamp(of: stored(trashed: nil), for: record), "Unknown is not safe.")
    }

    func testAnOriginalWithoutASavedCopyIsNeverProven() async {
        do {
            _ = try await ArchiveProver.prove(photoID: "missing", record: nil, wifi: ArchiveWiFi())
            XCTFail("Nothing may be deleted without a saved copy.")
        } catch {
            XCTAssertEqual(error as? ArchiveProofError, .notRecorded)
        }
    }

    // MARK: - Repeated names (1.0.2, D3)

    func testNumberedNames() {
        XCTAssertEqual(ArchiveNames.numbered("IMG_0001.HEIC", 1), "IMG_0001.HEIC")
        XCTAssertEqual(ArchiveNames.numbered("IMG_0001.HEIC", 2), "IMG_0001 (2).HEIC")
        XCTAssertEqual(ArchiveNames.numbered("IMG_0001.HEIC", 12), "IMG_0001 (12).HEIC")
        XCTAssertEqual(ArchiveNames.numbered("notes", 3), "notes (3)")
    }

    func testARepeatedNameGetsTheNextFreeNumberAndNothingIsOverwritten() throws {
        try withFolders { source, archive, restore in
            let first = Data(repeating: 1, count: 1_000)
            try first.write(to: source)
            let item = ArchiveItem(id: "a", name: "IMG_0001.HEIC", source: .file(source))
            let one = try VerifiedArchive.copyEvery(item, to: archive)
            XCTAssertEqual(one.receipt.url.lastPathComponent, "IMG_0001.HEIC")
            XCTAssertTrue(one.parts.isEmpty)

            let second = Data(repeating: 2, count: 2_000)
            try second.write(to: source)
            let two = try VerifiedArchive.copyEvery(ArchiveItem(id: "b", name: "IMG_0001.HEIC", source: .file(source)), to: archive)
            XCTAssertEqual(two.receipt.url.lastPathComponent, "IMG_0001 (2).HEIC", "The stored name is the one the record saves.")
            XCTAssertEqual(two.receipt.fingerprint.bytes, 2_000)

            // A gap is filled first: the numbers are decided by what is in the folder, nothing else.
            try Data([9]).write(to: archive.appendingPathComponent("IMG_0001 (4).HEIC"))
            let third = Data(repeating: 3, count: 3_000)
            try third.write(to: source)
            let three = try VerifiedArchive.copyEvery(ArchiveItem(id: "c", name: "IMG_0001.HEIC", source: .file(source)), to: archive)
            XCTAssertEqual(three.receipt.url.lastPathComponent, "IMG_0001 (3).HEIC")

            XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("IMG_0001.HEIC")), first)
            XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("IMG_0001 (2).HEIC")), second)
            XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("IMG_0001 (3).HEIC")), third)
            XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent("IMG_0001 (4).HEIC")), Data([9]), "Never overwritten.")
            XCTAssertEqual(try VerifiedArchive.restore(three.receipt, to: restore).lastPathComponent, "IMG_0001 (3).HEIC")
        }
    }

    func testTwoCopiesAtOnceNeverTakeTheSameName() throws {
        let folder = URL(fileURLWithPath: "/tmp/TidyAwayNames-\(UUID().uuidString)", isDirectory: true)
        let nothingThere: (URL) -> Bool = { _ in false }
        let first = try ArchiveNames.reserve({ [ArchiveNames.numbered("IMG_7.HEIC", $0)] }, in: folder, exists: nothingThere)
        let second = try ArchiveNames.reserve({ [ArchiveNames.numbered("img_7.heic", $0)] }, in: folder, exists: nothingThere)
        XCTAssertEqual(first.names, ["IMG_7.HEIC"])
        XCTAssertEqual(second.names, ["img_7 (2).heic"], "Names that differ only in case count as the same on most drives.")
        ArchiveNames.release(first.names, in: folder)
        ArchiveNames.release(second.names, in: folder)
        let again = try ArchiveNames.reserve({ [ArchiveNames.numbered("IMG_7.HEIC", $0)] }, in: folder, exists: nothingThere)
        XCTAssertEqual(again.number, 1, "Released names are free again.")
        ArchiveNames.release(again.names, in: folder)
    }

    func testEveryFileOfAnItemTakesTheSameNumber() throws {
        let folder = URL(fileURLWithPath: "/tmp/TidyAwayParts-\(UUID().uuidString)", isDirectory: true)
        // A Live Photo's video name is taken by something else; the still's name is free.
        let taken: Set<String> = ["IMG_9.MOV"]
        let exists: (URL) -> Bool = { taken.contains($0.lastPathComponent) }
        func names(_ number: Int) -> [String] {
            let primary = ArchiveNames.numbered("IMG_9.HEIC", number)
            return [primary, ArchivePlan.name(for: ArchivePlan.pairedVideo, primary: primary, resourceFilename: "IMG_9.MOV")]
        }
        let chosen = try ArchiveNames.reserve(names, in: folder, exists: exists)
        defer { ArchiveNames.release(chosen.names, in: folder) }
        XCTAssertEqual(chosen.names, ["IMG_9 (2).HEIC", "IMG_9 (2).MOV"])

        // Files already there that are this item's own, from a try that stopped, are used again.
        let resumed = try ArchiveNames.reserve({ [ArchiveNames.numbered("IMG_8.HEIC", $0)] }, in: folder,
                                               reuse: { $0 == 1 }, exists: { _ in true })
        defer { ArchiveNames.release(resumed.names, in: folder) }
        XCTAssertEqual(resumed.number, 1)
    }

    private func withFolders(_ work: (URL, URL, URL) throws -> Void) throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? files.removeItem(at: root) }
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        let restore = root.appendingPathComponent("restore", isDirectory: true)
        try files.createDirectory(at: archive, withIntermediateDirectories: true)
        try files.createDirectory(at: restore, withIntermediateDirectories: false)
        try work(root.appendingPathComponent("sample.bin"), archive, restore)
    }
}
