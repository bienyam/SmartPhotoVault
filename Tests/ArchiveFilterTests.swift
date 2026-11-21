import XCTest
import Photos
@testable import SmartPhotoVault

final class ArchiveFilterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func photo(_ id: String, bytes: Int64, yearsOld: Double = 3, favorite: Bool = false, screenshot: Bool = false,
                       albums: [String] = [], at location: (Double, Double)? = nil) -> AssetRecord {
        AssetRecord(id: id, filename: id, mediaType: PHAssetMediaType.image.rawValue, favorite: favorite,
                    createdAt: now.addingTimeInterval(-yearsOld * 365 * 86_400),
                    resources: [ResourceFingerprint(type: PHAssetResourceType.photo.rawValue, digest: id, bytes: bytes)],
                    issue: nil, isScreenshot: screenshot, albumIDs: albums,
                    latitude: location?.0, longitude: location?.1)
    }

    private func video(_ id: String, bytes: Int64, resources: Int = 1) -> AssetRecord {
        let parts = (0..<resources).map { ResourceFingerprint(type: PHAssetResourceType.video.rawValue, digest: "\(id)\($0)", bytes: bytes) }
        return AssetRecord(id: id, filename: id, mediaType: PHAssetMediaType.video.rawValue, favorite: false,
                           createdAt: now.addingTimeInterval(-86_400), resources: parts, issue: nil, albumIDs: [])
    }

    private func snapshot(_ assets: [AssetRecord]) -> ScanSnapshot {
        ScanSnapshot(date: now, limitedAccess: false, includedCloudDownloads: false, assets: assets,
                     albums: [AlbumInfo(id: "trip", title: "Trip")])
    }

    func testVideosAreSuggestedLargestFirstAndMultiFileVideosAreLeftOut() {
        let library = snapshot([video("small", bytes: 10), video("big", bytes: 900), video("slomo", bytes: 2_000, resources: 2), photo("p", bytes: 5_000)])
        let ids = ArchiveSuggestionFilter(kind: .videos).matches(in: library, now: now).map(\.id)
        XCTAssertEqual(ids, ["big", "small"])
    }

    func testPhotoKindsNeverIncludeVideosOrFavorites() {
        let library = snapshot([photo("keep", bytes: 10, favorite: true), photo("p", bytes: 20), video("v", bytes: 30)])
        XCTAssertEqual(ArchiveSuggestionFilter(kind: .photos).matches(in: library, now: now).map(\.id), ["p"])
    }

    func testAlbumFilter() {
        let library = snapshot([photo("in", bytes: 10, albums: ["trip"]), photo("out", bytes: 20)])
        XCTAssertEqual(ArchiveSuggestionFilter(albumID: "trip").matches(in: library, now: now).map(\.id), ["in"])
    }

    func testPlaceFilterUsesTheChosenArea() {
        let area = PlaceArea(minLatitude: 44.9, maxLatitude: 45.1, minLongitude: -93.4, maxLongitude: -93.1)
        let library = snapshot([photo("home", bytes: 10, at: (44.98, -93.27)), photo("away", bytes: 20, at: (40.71, -74.0)),
                                photo("unknown", bytes: 30)])
        XCTAssertEqual(ArchiveSuggestionFilter(place: area).matches(in: library, now: now).map(\.id), ["home"])
    }

    func testAgeAndSizeStillApply() {
        let library = snapshot([photo("recent", bytes: 50, yearsOld: 0.5), photo("old", bytes: 50, yearsOld: 3), photo("tiny", bytes: 1, yearsOld: 3)])
        let ids = ArchiveSuggestionFilter(olderThanYears: 2, minimumBytes: 10).matches(in: library, now: now).map(\.id)
        XCTAssertEqual(ids, ["old"])
    }

    func testLocationIsRoundedToAboutOneKilometre() {
        XCTAssertEqual(PlaceArea.rounded(44.98765), 44.99, accuracy: 0.0001)
        XCTAssertEqual(PlaceArea.rounded(-93.2649), -93.26, accuracy: 0.0001)
    }

    func testScansSavedBeforeArchiveFiltersAskForARescan() {
        let old = ScanSnapshot(date: now, limitedAccess: false, includedCloudDownloads: false, assets: [])
        XCTAssertFalse(old.recordsArchiveFilters)
        XCTAssertTrue(snapshot([]).recordsArchiveFilters)
    }
}
