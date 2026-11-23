import XCTest
import UIKit
@testable import SmartPhotoVault

final class ArchiveThumbnailsTests: XCTestCase {
    func testPhotoIDsWithSlashesMakeSafeFileNames() {
        let url = ArchiveThumbnails.url(for: "ABC-123/L0/001")
        XCTAssertFalse(url.lastPathComponent.contains("/"))
        XCTAssertEqual(url.pathExtension, "jpg")
        XCTAssertEqual(url, ArchiveThumbnails.url(for: "ABC-123/L0/001"), "The same photo always maps to the same file.")
        XCTAssertNotEqual(url, ArchiveThumbnails.url(for: "ABC-124/L0/001"))
    }

    func testAKeptPictureComesBack() throws {
        let id = "test-\(UUID().uuidString)/L0/001"
        let picture = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { context in
            UIColor.orange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        }
        XCTAssertNil(ArchiveThumbnails.cached(id))
        ArchiveThumbnails.store(picture, for: id)
        XCTAssertNotNil(ArchiveThumbnails.cached(id))
        try? FileManager.default.removeItem(at: ArchiveThumbnails.url(for: id))
    }

    func testCloudCopiesAreNotReadFromFiles() {
        let record = ArchivedRecord(id: "r", name: "a.jpg", folderName: "OneDrive", bytes: 1, digest: "", date: Date(),
                                    viaHomeServer: false, folderBookmark: nil, driveFileID: "x", cloud: .oneDrive)
        XCTAssertNil(ArchiveThumbnails.fromCopy(record))
    }
}
