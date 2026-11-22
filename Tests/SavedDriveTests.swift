import XCTest
@testable import SmartPhotoVault

final class SavedDriveTests: XCTestCase {
    func testADriveIsRememberedReadAndForgotten() throws {
        let name = UUID().uuidString
        let store = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { store.removePersistentDomain(forName: name) }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertNil(SavedDrive.load(store))
        SavedDrive.remember(folder, store)
        let saved = try XCTUnwrap(SavedDrive.load(store))
        XCTAssertEqual(saved.name, folder.lastPathComponent)
        let status = try XCTUnwrap(DriveStatus.read(saved))
        XCTAssertGreaterThan(status.total, 0)
        XCTAssertTrue((0...1).contains(status.usedFraction))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [], "Looking writes nothing.")
        try FileManager.default.removeItem(at: folder)
        XCTAssertNil(DriveStatus.read(saved), "Unplugged reads as not connected.")
        SavedDrive.forget(store)
        XCTAssertNil(SavedDrive.load(store))
    }
}
