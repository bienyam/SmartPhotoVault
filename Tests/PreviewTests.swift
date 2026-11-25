import XCTest
import Photos
@testable import SmartPhotoVault

/// Preview before delete: which items the viewer loads and what it says about each one.
final class PreviewTests: XCTestCase {
    private func record(_ id: String, name: String, video: Bool = false, bytes: Int64 = 3_700_000,
                        width: Int? = 4032, height: Int? = 3024, cloud: Int64? = nil, favorite: Bool = false) -> AssetRecord {
        AssetRecord(id: id, filename: name, mediaType: (video ? PHAssetMediaType.video : PHAssetMediaType.image).rawValue,
                    favorite: favorite, createdAt: Date(timeIntervalSince1970: 1_787_000_000),
                    resources: cloud == nil ? [ResourceFingerprint(type: 1, digest: id, bytes: bytes)] : [],
                    issue: nil, isScreenshot: false, subtypes: 0, pixelWidth: width, pixelHeight: height,
                    albumIDs: [], cloudBytes: cloud)
    }

    func testWindowIsCenteredOnTheTappedItem() {
        XCTAssertEqual(PreviewWindow.range(count: 1_000, index: 500, radius: 60), 440..<561)
        XCTAssertEqual(PreviewWindow.range(count: 1_000, index: 0, radius: 60), 0..<61)
        XCTAssertEqual(PreviewWindow.range(count: 1_000, index: 999, radius: 60), 939..<1_000)
        XCTAssertEqual(PreviewWindow.range(count: 5, index: 2, radius: 60), 0..<5, "A short list is shown whole.")
    }

    func testWindowNeverLeavesTheList() {
        XCTAssertEqual(PreviewWindow.range(count: 0, index: 3), 0..<0)
        XCTAssertEqual(PreviewWindow.range(count: 10, index: 99, radius: 2), 7..<10)
        XCTAssertEqual(PreviewWindow.range(count: 10, index: -4, radius: 2), 0..<3)
        for index in 0..<10 {
            XCTAssertTrue(PreviewWindow.range(count: 10, index: index, radius: 1).contains(index))
        }
    }

    func testFactsLineSaysSizeDimensionsKindAndPlace() {
        let photo = record("a", name: "IMG_4821.HEIC")
        XCTAssertEqual(PreviewFacts.kind(photo), "HEIC")
        XCTAssertEqual(PreviewFacts.dimensions(photo), "4032 × 3024")
        let line = PreviewFacts.line(photo)
        XCTAssertTrue(line.contains("4032 × 3024 · HEIC · on this "), line)
        XCTAssertTrue(line.hasPrefix(photo.displayBytes.fileSize), line)
    }

    func testFactsForAnItemKeptInICloudAndOneWithoutAType() {
        let cloud = record("b", name: "Birthday.mov", video: true, width: nil, height: nil, cloud: 410_000_000)
        XCTAssertTrue(cloud.inICloud)
        XCTAssertEqual(PreviewFacts.place(cloud), "in iCloud")
        XCTAssertNil(PreviewFacts.dimensions(cloud))
        XCTAssertTrue(PreviewFacts.line(cloud).hasSuffix("MOV · in iCloud"), PreviewFacts.line(cloud))
        XCTAssertEqual(PreviewFacts.kind(record("c", name: "clip", video: true)), "Video")
        XCTAssertEqual(PreviewFacts.kind(record("d", name: "scan")), "Photo")
    }

    func testTheViewerOffersNoDeleteWording() {
        for words in [PreviewWords(), PreviewWords.archive] {
            let all = [words.keep, words.select, words.selected, words.footer].joined(separator: " ").lowercased()
            XCTAssertFalse(all.contains("delete"), all)
            XCTAssertFalse(all.contains("trash"), all)
        }
        XCTAssertTrue(PreviewWords().footer.contains("Nothing is removed from this screen"))
    }
}
