import XCTest
@testable import SmartPhotoVault

final class CloudDownloadRemovalTests: XCTestCase {
    func testRejectsLocalOnlyFileWithoutChangingIt() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let data = Data("keep this file".utf8)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try CloudDownloadRemovalPlan.inspect(url))
        XCTAssertEqual(try Data(contentsOf: url), data)
    }
}
