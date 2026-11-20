import XCTest
import Photos
@testable import SmartPhotoVault

final class CleanCategoryTests: XCTestCase {
    private func record(_ id: String, bytes: Int64, subtypes: PHAssetMediaSubtype = [], issue: String? = nil,
                        animated: Bool = false, burstID: String? = nil) -> AssetRecord {
        let resources = issue == nil ? [ResourceFingerprint(type: 1, digest: id, bytes: bytes)] : []
        return AssetRecord(id: id, filename: id, mediaType: 1, favorite: false, createdAt: nil, resources: resources, issue: issue,
                           subtypes: subtypes.rawValue, animated: animated, burstID: burstID)
    }
    private func snapshot(_ assets: [AssetRecord]) -> ScanSnapshot {
        ScanSnapshot(date: Date(), limitedAccess: false, includedCloudDownloads: false, assets: assets)
    }

    func testSampleLibraryHasEveryCategory() {
        let sample = DemoLibrary.snapshot
        XCTAssertTrue(sample.recordsCategories)
        let counts = Dictionary(uniqueKeysWithValues: CleanCategory.allCases.map { ($0, sample.summary(for: $0).items.count) })
        XCTAssertEqual(counts, [.screenshots: 1, .gifs: 1, .bursts: 1, .livePhotos: 2, .sloMo: 1, .timeLapse: 1, .panoramas: 1])
    }

    func testItemsSortLargestFirstAndUnreadItemsAreNotCounted() {
        let result = snapshot([
            record("small", bytes: 10, subtypes: .photoScreenshot),
            record("unread", bytes: 0, subtypes: .photoScreenshot, issue: "Not on this iPhone"),
            record("large", bytes: 500, subtypes: .photoScreenshot),
            record("other", bytes: 900)
        ]).summary(for: .screenshots)
        XCTAssertEqual(result.items.map(\.id), ["large", "small", "unread"])
        XCTAssertEqual(result.knownBytes, 510)
        XCTAssertEqual(result.unreadCount, 1)
    }

    func testOneAssetCanBelongToSeveralCategories() {
        let live = record("pano", bytes: 1, subtypes: [.photoPanorama, .photoLive])
        XCTAssertTrue(CleanCategory.panoramas.includes(live))
        XCTAssertTrue(CleanCategory.livePhotos.includes(live))
        XCTAssertFalse(CleanCategory.screenshots.includes(live))
    }

    func testGIFsAndBurstsUseTheirOwnFields() {
        XCTAssertTrue(CleanCategory.gifs.includes(record("gif", bytes: 1, animated: true)))
        XCTAssertTrue(CleanCategory.bursts.includes(record("burst", bytes: 1, burstID: "b")))
        XCTAssertFalse(CleanCategory.bursts.includes(record("single", bytes: 1)))
    }

    func testEachBurstIsListedOnceAndCountsItsHiddenFrames() {
        var first = record("b1", bytes: 10, burstID: "burst")
        first.burstFrames = 9
        var pick = record("b2", bytes: 20, burstID: "burst")
        pick.burstFrames = 9
        var other = record("c1", bytes: 5, burstID: "other")
        other.burstFrames = 3
        let result = snapshot([first, pick, other]).summary(for: .bursts)
        XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(result.burstFrames, 12)
        XCTAssertEqual(snapshot([first, other]).cleanSummaries().map(\.category), CleanCategory.allCases)
    }

    func testScansSavedBeforeCategoriesStillLoadAndAskForARescan() throws {
        let old = """
        {"date":0,"limitedAccess":false,"includedCloudDownloads":false,"assets":[
          {"id":"a","filename":"a","mediaType":1,"favorite":false,"resources":[{"type":1,"digest":"d","bytes":5}],"isScreenshot":true}
        ]}
        """
        let decoded = try JSONDecoder().decode(ScanSnapshot.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.assets.count, 1)
        XCTAssertFalse(decoded.recordsCategories)
        XCTAssertTrue(snapshot([]).recordsCategories)
    }

    func testCategoryFieldsSurviveTheLocalStore() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try InventoryStore(url: path)
        try store.save(DemoLibrary.snapshot)
        let loaded = try XCTUnwrap(store.load())
        XCTAssertEqual(loaded.summary(for: .bursts).items.first?.burstFrames, 14)
        XCTAssertEqual(loaded.summary(for: .sloMo).items.map(\.id), ["sample-10"])
    }
}
