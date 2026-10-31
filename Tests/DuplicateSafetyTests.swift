import XCTest
@testable import SmartPhotoVault

final class DuplicateSafetyTests: XCTestCase {
    private let still = ResourceFingerprint(type: 1, digest: "still", bytes: 100)
    private let motion = ResourceFingerprint(type: 9, digest: "motion", bytes: 200)

    private func asset(_ id: String, _ resources: [ResourceFingerprint], issue: String? = nil, favorite: Bool = false) -> AssetRecord {
        AssetRecord(id: id, filename: id, mediaType: 1, favorite: favorite, createdAt: nil, resources: resources, issue: issue)
    }
    private func snapshot(_ assets: [AssetRecord]) -> ScanSnapshot {
        ScanSnapshot(date: Date(), limitedAccess: false, includedCloudDownloads: false, assets: assets)
    }

    func testLivePhotoWithDifferentMotionIsNotExactDuplicate() {
        let different = ResourceFingerprint(type: 9, digest: "different", bytes: 200)
        XCTAssertTrue(snapshot([asset("a", [still, motion]), asset("b", [still, different])]).groups.isEmpty)
    }
    func testPartialResourceFailureAndEmptyResourcesAreExcluded() {
        let result = snapshot([asset("a", [still]), asset("b", [still], issue: "Could not read paired video"), asset("c", [])])
        XCTAssertEqual(result.verifiedCount, 1)
        XCTAssertTrue(result.groups.isEmpty)
    }
    func testOrderDoesNotMatterButResourceMultiplicityDoes() {
        let result = snapshot([asset("a", [still, motion]), asset("b", [motion, still]), asset("c", [still, motion, motion])])
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].assets.count, 2)
        XCTAssertEqual(result.candidateBytes, 300)
    }
    func testFavoritesAppearFirstAndAreNotCountedAsExtraCopy() {
        let result = snapshot([asset("a", [still]), asset("b", [still], favorite: true), asset("c", [still])])
        XCTAssertEqual(result.groups[0].assets.first?.id, "b")
        XCTAssertEqual(result.candidateBytes, 200)
    }
    func testResourceTypesMustMatch() {
        XCTAssertTrue(snapshot([asset("a", [still]), asset("b", [ResourceFingerprint(type: 5, digest: "still", bytes: 100)])]).groups.isEmpty)
    }
    func testSyntheticLibraryHasOneDuplicateGroupAndOneUnreadableAsset() {
        let result = DemoLibrary.snapshot
        XCTAssertEqual(result.assets.count, 5)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.verifiedCount, 4)
    }
    func testDatabaseRoundTripAndActivityLog() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try InventoryStore(url: path)
        XCTAssertNil(try store.load())
        let original = DemoLibrary.snapshot
        try store.save(original)
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.assets.count, original.assets.count)
        XCTAssertEqual(loaded.groups.count, original.groups.count)
        XCTAssertEqual(loaded.candidateBytes, original.candidateBytes)
        XCTAssertEqual(try store.activity().count, 1)
        try store.log("Apostrophes ' and Unicode 📷 stay intact")
        XCTAssertEqual(try store.activity().first?.message, "Apostrophes ' and Unicode 📷 stay intact")
        try store.save(snapshot([]))
        XCTAssertEqual(try store.load()?.assets.count, 0)
        XCTAssertEqual(try store.activity().count, 3)
    }
}
