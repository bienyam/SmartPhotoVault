import XCTest
import Photos
@testable import SmartPhotoVault

/// With Optimize iPhone Storage on, most originals are only in iCloud. They must still be listed.
final class ICloudItemsTests: XCTestCase {
    private func video(_ id: String, local: Int64? = nil, cloud: Int64? = nil) -> AssetRecord {
        let resources = local.map { [ResourceFingerprint(type: 2, digest: id, bytes: $0)] } ?? []
        return AssetRecord(id: id, filename: "\(id).mov", mediaType: PHAssetMediaType.video.rawValue, favorite: false,
                           createdAt: nil, resources: resources, issue: local == nil ? "Original is in iCloud." : nil,
                           subtypes: 0, cloudBytes: cloud)
    }

    func testICloudOnlyVideosAreListedLargestFirst() {
        let snapshot = ScanSnapshot(date: Date(), limitedAccess: false, includedCloudDownloads: false, assets: [
            video("local", local: 300),
            video("cloud-big", cloud: 900),
            video("cloud-small", cloud: 100),
            video("unknown")
        ])
        let rescue = RescueSummary(snapshot: snapshot)
        XCTAssertEqual(rescue.videos.map(\.id), ["cloud-big", "local", "cloud-small"],
                       "iCloud-only videos are listed by their reported size; ones with no size are left out.")
        XCTAssertEqual(rescue.videoBytes, 1_300)
        XCTAssertTrue(rescue.includesICloud)
        XCTAssertTrue(rescue.videos[0].inICloud)
        XCTAssertFalse(rescue.videos[1].inICloud)
    }

    func testICloudOnlyScreenshotsCountTowardTheRow() {
        var shot = AssetRecord(id: "s", filename: "s.png", mediaType: PHAssetMediaType.image.rawValue, favorite: false,
                               createdAt: nil, resources: [], issue: "Original is in iCloud.", isScreenshot: true,
                               subtypes: PHAssetMediaSubtype.photoScreenshot.rawValue)
        shot.cloudBytes = 2_000
        let snapshot = ScanSnapshot(date: Date(), limitedAccess: false, includedCloudDownloads: false, assets: [shot])
        let summary = snapshot.summary(for: .screenshots)
        XCTAssertEqual(summary.items.count, 1)
        XCTAssertEqual(summary.displayBytes, 2_000)
        XCTAssertEqual(summary.knownBytes, 0, "Read-on-iPhone bytes stay separate.")
    }

    func testICloudItemsAreNeverDuplicates() {
        let snapshot = ScanSnapshot(date: Date(), limitedAccess: false, includedCloudDownloads: false, assets: [
            video("a", cloud: 500), video("b", cloud: 500)
        ])
        XCTAssertTrue(snapshot.groups.isEmpty, "Same reported size is not proof of a duplicate.")
    }
}
