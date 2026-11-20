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
