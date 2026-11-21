import XCTest
@testable import SmartPhotoVault

final class FolderCheckTests: XCTestCase {
    func testNTFSDrivesAreExplainedAndBlocked() {
        let check = FolderCheck(format: "Windows NT Filesystem (NTFS)", readOnly: true, available: 10, writable: false)
        XCTAssertTrue(check.isNTFS)
        XCTAssertTrue(check.problem?.contains("formatted for Windows (NTFS)") == true)
        XCTAssertTrue(check.problem?.contains("Erase") == true, "It says how to fix it on the iPhone.")
        XCTAssertTrue(check.problem?.contains("deletes everything") == true, "It warns that erasing wipes the drive.")
    }

    func testFAT32IsAllowedButFlaggedAndExFATIsNot() {
        let fat = FolderCheck(format: "MS-DOS (FAT32)", readOnly: false, available: 10, writable: true)
        XCTAssertTrue(fat.isFAT32)
        XCTAssertNil(fat.problem)
        let exfat = FolderCheck(format: "ExFAT", readOnly: false, available: 10, writable: true)
        XCTAssertFalse(exfat.isFAT32)
        XCTAssertNil(exfat.problem)
    }

    func testUnwritableFolderIsAProblem() {
        let check = FolderCheck(format: "APFS", readOnly: false, available: nil, writable: false)
        XCTAssertNotNil(check.problem)
    }

    func testRunOnAWritableFolderLeavesNothingBehind() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("keep".utf8).write(to: folder.appendingPathComponent("existing.txt"))
        let check = FolderCheck.run(on: folder)
        XCTAssertTrue(check.writable)
        XCTAssertNil(check.problem)
        XCTAssertNotNil(check.available)
        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(contents, ["existing.txt"], "The test write is removed and existing files are untouched.")
    }
}
