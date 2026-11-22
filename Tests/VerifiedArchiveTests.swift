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
