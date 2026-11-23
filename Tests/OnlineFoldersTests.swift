import XCTest
@testable import SmartPhotoVault

final class OnlineFoldersTests: XCTestCase {
    func testFolderNamesAreCleaned() {
        XCTAssertEqual(OnlineFolders.cleanName("  2024 Beach trip  "), "2024 Beach trip")
        XCTAssertEqual(OnlineFolders.cleanName("a/b:c*d?"), "abcd")
        XCTAssertNil(OnlineFolders.cleanName("  /  "))
        XCTAssertNil(OnlineFolders.cleanName("..."))
    }

    func testPathsAreShownInsideTidyAwaysOwnFolder() {
        let folder = OnlineFolder(id: "Trips/Beach", path: "Trips/Beach")
        XCTAssertEqual(folder.shown(in: .oneDrive), "OneDrive › Apps › TidyAway › Trips › Beach")
        XCTAssertEqual(folder.label(in: .dropbox), "Dropbox › Trips › Beach")
        XCTAssertEqual(OnlineFolder.root.shown(in: .dropbox), "Dropbox › Apps › TidyAway")
        XCTAssertEqual(OnlineFolder.root.label(in: .oneDrive), "OneDrive")
        XCTAssertEqual(OnlineFolders.joined(.root, "IMG_1.HEIC"), "IMG_1.HEIC")
        XCTAssertEqual(OnlineFolders.joined(folder, "IMG_1.HEIC"), "Trips/Beach/IMG_1.HEIC")
    }

    func testOneDrivePathsAreEncodedPartByPart() {
        XCTAssertEqual(OnlineFolders.graphPath("Beach trip/IMG #1.HEIC"), "Beach%20trip/IMG%20%231.HEIC")
    }

    func testTheChoiceIsRememberedPerService() {
        let defaults = UserDefaults(suiteName: "OnlineFoldersTests-\(UUID().uuidString)")!
        XCTAssertTrue(OnlineFolders.chosen(.oneDrive, defaults: defaults).isRoot)
        OnlineFolders.choose(OnlineFolder(id: "Trips", path: "Trips"), for: .oneDrive, defaults: defaults)
        XCTAssertEqual(OnlineFolders.chosen(.oneDrive, defaults: defaults).path, "Trips")
        XCTAssertTrue(OnlineFolders.chosen(.dropbox, defaults: defaults).isRoot)
        OnlineFolders.choose(.root, for: .oneDrive, defaults: defaults)
        XCTAssertTrue(OnlineFolders.chosen(.oneDrive, defaults: defaults).isRoot)
    }
}
