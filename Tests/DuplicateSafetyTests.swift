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
    func testRemovalPlanKeepsTheFirstCopyAndNeverRemovesFavorites() throws {
        let group = try XCTUnwrap(snapshot([asset("a", [still]), asset("b", [still], favorite: true), asset("c", [still]), asset("d", [still], favorite: true)]).groups.first)
        let plan = try XCTUnwrap(DuplicateRemovalPlan(group: group))
        XCTAssertTrue(["b", "d"].contains(plan.keepID), "A favorite is kept.")
        XCTAssertEqual(plan.removeIDs.sorted(), ["a", "c"], "Only non-favorite extra copies are removable.")
        XCTAssertEqual(plan.removeBytes, 200)
        XCTAssertEqual(plan.deleteLabel, "Delete 2 items from Apple Photos")
    }
    func testRemovalPlanIsUnavailableWhenEveryExtraCopyIsAFavorite() throws {
        let group = try XCTUnwrap(snapshot([asset("a", [still], favorite: true), asset("b", [still], favorite: true)]).groups.first)
        XCTAssertNil(DuplicateRemovalPlan(group: group))
    }
    func testSampleRemovalPlanRemovesOnlyTheCopy() throws {
        let group = try XCTUnwrap(DemoLibrary.snapshot.groups.first)
        let plan = try XCTUnwrap(DuplicateRemovalPlan(group: group))
        XCTAssertEqual(plan.keepID, "sample-1")
        XCTAssertEqual(plan.removeIDs, ["sample-2"])
        XCTAssertEqual(plan.deleteLabel, "Delete 1 item from Apple Photos")
    }
    func testRemovingDeletedItemsKeepsTheRestOfTheScan() {
        let original = DemoLibrary.snapshot
        let updated = original.removing(["sample-2", "sample-6"])
        XCTAssertEqual(updated.assets.count, original.assets.count - 2)
        XCTAssertTrue(updated.groups.isEmpty, "With the extra copy gone, the duplicate group disappears.")
        XCTAssertTrue(updated.assets.contains { $0.id == "sample-1" }, "The kept copy stays.")
        XCTAssertTrue(updated.summary(for: .screenshots).items.isEmpty)
        XCTAssertEqual(updated.date, original.date)
    }
    func testRescueRowsDropDeletedItemsDuringACheck() {
        let rescue = RescueSummary(snapshot: DemoLibrary.snapshot)
        XCTAssertEqual(rescue.duplicateCopies, 1)
        XCTAssertEqual(rescue.screenshots.items.count, 1)
        let after = rescue.removing(["sample-2", "sample-6"])
        XCTAssertEqual(after.duplicateCopies, 0)
        XCTAssertTrue(after.screenshots.items.isEmpty)
        XCTAssertEqual(after.videos.count, rescue.videos.count, "Other rows are unchanged.")
    }
    func testRemovalMessageNeverClaimsSpaceIsFreedYet() {
        let message = DuplicateRemovalOutcome.removedMessage(count: 2, bytes: 2_000_000)
        XCTAssertTrue(message.hasPrefix("Moved 2 items to Recently Deleted."))
        XCTAssertTrue(message.contains("Empty it in Photos to free about"))
        XCTAssertFalse(message.contains("Removed"))
    }
    func testSyntheticLibraryHasOneDuplicateGroupAndOneUnreadableAsset() {
        let result = DemoLibrary.snapshot
        XCTAssertEqual(result.assets.count, 12)
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.verifiedCount, 11)
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
