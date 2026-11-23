import CoreGraphics
import Photos
import Vision
import XCTest
@testable import SmartPhotoVault

final class RecognitionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var old: TimeInterval { now.timeIntervalSince1970 - 3 * 365 * 86_400 }

    private func photo(_ id: String, _ seconds: TimeInterval, bytes: Int64 = 3_000_000, favorite: Bool = false, albums: [String] = []) -> AssetRecord {
        AssetRecord(id: id, filename: "\(id).HEIC", mediaType: PHAssetMediaType.image.rawValue, favorite: favorite,
                    createdAt: Date(timeIntervalSince1970: seconds),
                    resources: [ResourceFingerprint(type: PHAssetResourceType.photo.rawValue, digest: id, bytes: bytes)],
                    issue: nil, isScreenshot: false, subtypes: 0, albumIDs: albums)
    }

    private func video(_ id: String, _ seconds: TimeInterval, bytes: Int64, subtypes: UInt = 0, width: Int = 1920) -> AssetRecord {
        AssetRecord(id: id, filename: "\(id).MOV", mediaType: PHAssetMediaType.video.rawValue, favorite: false,
                    createdAt: Date(timeIntervalSince1970: seconds),
                    resources: [ResourceFingerprint(type: PHAssetResourceType.video.rawValue, digest: id, bytes: bytes)],
                    issue: nil, isScreenshot: false, subtypes: subtypes, pixelWidth: width, pixelHeight: 1080, albumIDs: [])
    }

    private func snapshot(_ assets: [AssetRecord]) -> ScanSnapshot {
        ScanSnapshot(date: now, limitedAccess: false, includedCloudDownloads: false, assets: assets)
    }

    private func day(_ count: Int, _ labels: (Int) -> [String]) -> ([AssetRecord], [String: PhotoInsight]) {
        let photos = (0..<count).map { photo("p\(String(format: "%03d", $0))", old + Double($0) * 120) }
        var insights: [String: PhotoInsight] = [:]
        for (index, photo) in photos.enumerated() { insights[photo.id] = PhotoInsight(id: photo.id, labels: labels(index)) }
        return (photos, insights)
    }

    func testAnEventIsNamedByWhatItShowsAndTheDateBecomesSmallPrint() throws {
        let (photos, insights) = day(40) { $0 < 16 ? ["beach"] : [] }
        let group = try XCTUnwrap(SmartGrouper.groups(in: snapshot(photos), insights: insights, facts: [:], now: now).first { $0.kind == .event })
        XCTAssertEqual(group.title, "Beach day")
        XCTAssertNotNil(group.when)
        XCTAssertEqual(group.reason, "Looks like a beach, in 40% of the pictures")
    }

    func testOneCakeOutweighsManyBeachPictures() {
        let (photos, insights) = day(50) { $0 < 2 ? ["birthday_cake"] : ["beach"] }
        XCTAssertEqual(Recognition.moment(for: photos, insights: insights)?.moment.name, "Birthday party")
    }

    func testNothingStandingOutKeepsTheDateAndFewResultsNameNothing() {
        let (photos, insights) = day(40) { $0 < 5 ? ["beach"] : [] }
        XCTAssertNil(Recognition.moment(for: photos, insights: insights), "5 of 40 is not a beach day.")
        let (more, all) = day(40) { _ in ["beach"] }
        let some = all.filter { $0.key < "p015" }
        XCTAssertNil(Recognition.moment(for: more, insights: some), "Too little looked at so far.")
    }

    func testTopicsNeedEnoughAndLeaveOutFavorites() {
        var photos = (0..<15).map { photo("f\($0)", old + Double($0) * 90_000) }
        photos.append(photo("fav", old + 2_000_000, favorite: true))
        var insights = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, PhotoInsight(id: $0.id, labels: ["food"])) })
        func food() -> SmartGroup? { SmartGrouper.groups(in: snapshot(photos), insights: insights, facts: [:], now: now).first { $0.id == "topic-food" } }
        XCTAssertEqual(food()?.records.count, 15)
        insights["f0"] = PhotoInsight(id: "f0")
        XCTAssertNil(food(), "14 is too few to be worth a group.")
    }

    func testSameShotsKeepTheSharpestAndNeverIncludeFavoritesOrEdits() {
        let photos = (0..<8).map { photo("s\($0)", old + Double($0) * 2, favorite: $0 == 3) }
        var insights: [String: PhotoInsight] = [:]
        for (index, photo) in photos.enumerated() {
            insights[photo.id] = PhotoInsight(id: photo.id, sharpness: Double(index), sameAs: index == 0 ? nil : "s\(index - 1)")
        }
        XCTAssertEqual(SmartGrouper.series(in: photos, insights: insights).map(\.count), [8])
        XCTAssertEqual(SmartGrouper.best(of: photos, insights: insights, facts: [:])?.id, "s3", "A favorite always stays.")
        let plain = photos.filter { !$0.favorite }
        XCTAssertEqual(SmartGrouper.best(of: plain, insights: insights, facts: [:])?.id, "s7", "Then the sharpest.")
        XCTAssertEqual(SmartGrouper.best(of: plain, insights: insights, facts: ["s1": AssetFacts(edited: true)])?.id, "s1", "Then one that was edited.")
        let extras = SmartGrouper.extras(in: photos, insights: insights, facts: ["s5": AssetFacts(edited: true)]).map(\.id)
        XCTAssertFalse(extras.contains("s3"))
        XCTAssertFalse(extras.contains("s5"))
        XCTAssertEqual(extras.count, 6)
    }

    func testPickReachesTheGoalAndLeavesOutWhatMatters() throws {
        var assets = (0..<30).map { video("v\(String(format: "%02d", $0))", old + Double($0) * 90_000, bytes: 400_000_000) }
        assets.append(photo("fav", old, bytes: 900_000_000, favorite: true))
        assets.append(video("recent", now.timeIntervalSince1970 - 5 * 86_400, bytes: 300_000_000))
        assets.append(photo("album", old, bytes: 300_000_000, albums: ["1"]))
        let edited = video("edited", old, bytes: 400_000_000)
        assets.append(edited)
        let pick = try XCTUnwrap(SmartGrouper.pick(goal: 5, in: assets, insights: [:], facts: ["edited": AssetFacts(duration: 10, edited: true)], now: now))
        XCTAssertGreaterThanOrEqual(pick.bytes, 5_000_000_000)
        XCTAssertLessThan(pick.bytes, 5_400_000_001, "It stops once the goal is reached.")
        let ids = Set(pick.records.map(\.id))
        XCTAssertFalse(ids.contains("fav"))
        XCTAssertFalse(ids.contains("recent"))
        XCTAssertNil(SmartGrouper.pick(goal: 5, in: [photo("fav", old, favorite: true)], insights: [:], facts: [:], now: now))
    }

    func testVideoGroupsUseLengthSizeAndType() {
        let assets = [video("long", old, bytes: 50_000_000), video("uhd", old + 90_000, bytes: 60_000_000, width: 3840),
                      video("screen", old + 180_000, bytes: 10_000_000, subtypes: 524_288),
                      video("lapse", old + 270_000, bytes: 10_000_000, subtypes: PHAssetMediaSubtype.videoTimelapse.rawValue)]
        let groups = SmartGrouper.groups(in: snapshot(assets), insights: [:], facts: ["long": AssetFacts(duration: 400)], now: now)
        func ids(_ id: String) -> [String]? { groups.first { $0.id == id }?.records.map(\.id) }
        XCTAssertEqual(ids("long-videos"), ["long"])
        XCTAssertEqual(ids("4k-videos"), ["uhd"])
        XCTAssertEqual(ids("screen-recordings"), ["screen"])
        XCTAssertEqual(ids("time-lapse"), ["lapse"])
    }

    func testResultsAreSavedAsTheyComeAndOldOnesDropped() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = InsightStore(url: url)
        await store.append([PhotoInsight(id: "a", labels: ["beach"]), PhotoInsight(id: "b")])
        await store.append([PhotoInsight(id: "a", labels: ["food"], sameAs: "b"), PhotoInsight(id: "c", version: 0)])
        var loaded = await InsightStore(url: url).load()
        XCTAssertEqual(loaded["a"]?.labels, ["food"], "The newest result counts.")
        XCTAssertEqual(loaded["a"]?.sameAs, "b")
        XCTAssertNil(loaded["c"], "An older kind of result is read again.")
        await store.keep(only: ["b"])
        loaded = await store.load()
        XCTAssertEqual(Array(loaded.keys), ["b"], "Photos that are gone are forgotten.")
    }

    func testSharpPicturesScoreHigherThanFlatOnes() throws {
        func image(_ draw: (CGContext) -> Void) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.setFillColor(gray: 0.5, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
            draw(context)
            return try XCTUnwrap(context.makeImage())
        }
        let flat = try image { _ in }
        let sharp = try image { context in
            context.setFillColor(gray: 1, alpha: 1)
            for x in stride(from: 0, to: 256, by: 16) { context.fill(CGRect(x: x, y: 0, width: 8, height: 256)) }
        }
        XCTAssertGreaterThan(InsightReader.sharpness(of: sharp), InsightReader.sharpness(of: flat) + 10)
    }

    func testEveryLabelWeGroupByIsOneTheIPhoneKnows() throws {
        let supported = Set(try VNClassifyImageRequest().supportedIdentifiers())
        print("VISION-TAXONOMY \(supported.count): " + supported.sorted().joined(separator: ","))
        XCTAssertEqual(Recognition.known.subtracting(supported).sorted(), [])
    }

    func testTooDarkPhotosFormAGroupButNeverFavorites() throws {
        var photos = (0..<6).map { photo("d\($0)", old + Double($0) * 60) }
        photos.append(photo("dfav", old + 1_000, favorite: true))
        photos.append(photo("bright", old + 2_000))
        var insights: [String: PhotoInsight] = [:]
        for record in photos { insights[record.id] = PhotoInsight(id: record.id, brightness: record.id == "bright" ? 120 : 4) }
        insights["d5"] = PhotoInsight(id: "d5")
        func dark() -> SmartGroup? { SmartGrouper.groups(in: snapshot(photos), insights: insights, facts: [:], now: now).first { $0.id == "topic-dark" } }
        XCTAssertEqual(try XCTUnwrap(dark()).records.map(\.id), ["d0", "d1", "d2", "d3", "d4"], "Not measured yet, a favorite, or bright: left out.")
        insights["d0"] = PhotoInsight(id: "d0", brightness: 80)
        XCTAssertNil(dark(), "Four is too few.")
    }

    func testBrightnessTellsBlackFromDaylight() throws {
        func image(_ gray: CGFloat) throws -> CGImage {
            let context = try XCTUnwrap(CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.setFillColor(gray: gray, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
            return try XCTUnwrap(context.makeImage())
        }
        XCTAssertLessThan(InsightReader.brightness(of: try image(0.02)), SmartGrouper.darkLevel)
        XCTAssertGreaterThan(InsightReader.brightness(of: try image(0.5)), 100)
    }

    func testReminderPicturesNeedFewerToFormAGroup() {
        let photos = (0..<8).map { photo("park\($0)", old + Double($0) * 90_000) }
        let insights = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, PhotoInsight(id: $0.id, labels: ["parking_lot"])) })
        let groups = SmartGrouper.groups(in: snapshot(photos), insights: insights, facts: [:], now: now)
        XCTAssertEqual(groups.first { $0.id == "topic-parking" }?.records.count, 8)
        XCTAssertNil(SmartGrouper.groups(in: snapshot(Array(photos.prefix(7))), insights: insights, facts: [:], now: now).first { $0.id == "topic-parking" })
    }

    func testOnlyLabelsWeGroupByAreKept() {
        XCTAssertTrue(Recognition.known.contains("beach"))
        XCTAssertTrue(Recognition.known.contains("receipt"))
        XCTAssertFalse(Recognition.known.contains("people"))
        XCTAssertFalse(Recognition.known.contains("child"))
    }
}
