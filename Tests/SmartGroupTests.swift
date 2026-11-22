import Photos
import XCTest
@testable import SmartPhotoVault

final class SmartGroupTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let home = (44.95, -93.10)
    private let away = (36.10, -112.10)

    private func photo(_ id: String, _ seconds: TimeInterval, at place: (Double, Double)? = nil, bytes: Int64 = 3_000_000,
                       name: String? = nil, live: Bool = false, screenshot: Bool = false, favorite: Bool = false) -> AssetRecord {
        AssetRecord(id: id, filename: name ?? "\(id).HEIC", mediaType: PHAssetMediaType.image.rawValue, favorite: favorite,
                    createdAt: Date(timeIntervalSince1970: seconds),
                    resources: [ResourceFingerprint(type: PHAssetResourceType.photo.rawValue, digest: id, bytes: bytes)],
                    issue: nil, isScreenshot: screenshot,
                    subtypes: (live ? PHAssetMediaSubtype.photoLive : []).rawValue,
                    latitude: place?.0, longitude: place?.1)
    }

    private func video(_ id: String, _ seconds: TimeInterval, bytes: Int64, favorite: Bool = false, albums: [String]? = []) -> AssetRecord {
        AssetRecord(id: id, filename: "\(id).MOV", mediaType: PHAssetMediaType.video.rawValue, favorite: favorite,
                    createdAt: Date(timeIntervalSince1970: seconds),
                    resources: [ResourceFingerprint(type: PHAssetResourceType.video.rawValue, digest: id, bytes: bytes)],
                    issue: nil, isScreenshot: false, subtypes: 0, albumIDs: albums)
    }

    private func snapshot(_ assets: [AssetRecord]) -> ScanSnapshot {
        ScanSnapshot(date: now, limitedAccess: false, includedCloudDownloads: false, assets: assets)
    }

    private func run(_ prefix: String, from start: TimeInterval, count: Int, every: TimeInterval = 120,
                     at place: (Double, Double)? = nil) -> [AssetRecord] {
        (0..<count).map { photo("\(prefix)\(String(format: "%03d", $0))", start + Double($0) * every, at: place) }
    }

    func testTwoPartiesOnDifferentDaysAreTwoEvents() {
        let first = run("a", from: 1_700_000_000, count: 30, at: home)
        let second = run("b", from: 1_700_000_000 + 3 * 86_400, count: 25, at: home)
        let groups = SmartGrouper.groups(in: snapshot(first + second), now: now, calendar: calendar)
        XCTAssertEqual(groups.filter { $0.kind == .event }.map(\.records.count).sorted(), [25, 30])
        XCTAssertTrue(groups.allSatisfy { $0.reason.hasPrefix("Taken ") && $0.reason.hasSuffix("same area") })
    }

    func testALongPauseInOneDaySplitsMorningFromEvening() {
        let morning = run("a", from: 1_700_000_000, count: 22)
        let evening = run("b", from: 1_700_000_000 + 5 * 3_600, count: 22)
        XCTAssertEqual(SmartGrouper.segments(in: morning + evening).map(\.count), [22, 22])
    }

    func testShortPausesStayTogetherAndSmallSetsAreNotEvents() {
        let party = run("a", from: 1_700_000_000, count: 10, every: 5) + run("b", from: 1_700_000_000 + 1_500, count: 10, every: 5)
        XCTAssertEqual(SmartGrouper.segments(in: party).count, 1, "A 24-minute pause is still the same event.")
        XCTAssertTrue(SmartGrouper.groups(in: snapshot(run("c", from: 1_700_000_000, count: 19)), now: now, calendar: calendar).isEmpty)
    }

    func testEventsLeaveOutScreenshotsAndCountWhatCannotBeArchivedYet() {
        var items = run("a", from: 1_700_000_000, count: 20)
        items.append(photo("live", 1_700_000_100, live: true))
        items.append(photo("png", 1_700_000_160, name: "drawing.png"))
        items.append(photo("shot", 1_700_000_200, screenshot: true))
        let group = SmartGrouper.groups(in: snapshot(items), now: now, calendar: calendar).first
        XCTAssertEqual(group?.records.count, 20)
        XCTAssertEqual(group?.notYet, 2)
        XCTAssertEqual(group?.total, 22)
        XCTAssertFalse(group?.records.contains { $0.id == "shot" } ?? true)
    }

    func testTripIsSeveralDaysFarFromHomeAndReplacesItsEvents() {
        let start: TimeInterval = 1_700_000_000
        let atHome = run("h", from: start, count: 60, at: home)
        let day1 = run("x", from: start + 10 * 86_400, count: 30, at: away)
        let day2 = run("y", from: start + 11 * 86_400, count: 30, at: away)
        let groups = SmartGrouper.groups(in: snapshot(atHome + day1 + day2), now: now, calendar: calendar)
        XCTAssertEqual(groups.filter { $0.kind == .trip }.map(\.records.count), [60])
        XCTAssertEqual(groups.filter { $0.kind == .event }.map(\.records.count), [60], "Only the event at home is left as an event.")
    }

    func testWithoutLocationsThereAreEventsButNoTrips() {
        let items = run("a", from: 1_700_000_000, count: 25) + run("b", from: 1_700_000_000 + 86_400, count: 25)
        let groups = SmartGrouper.groups(in: snapshot(items), now: now, calendar: calendar)
        XCTAssertEqual(groups.map(\.kind), [.event, .event])
    }

    func testVeryLargeVideosUse500MBOrTheLargestTen() {
        let recent = now.timeIntervalSince1970 - 86_400
        let huge = (0..<6).map { video("h\($0)", recent - Double($0) * 90_000, bytes: 600_000_000) }
        let mid = (0..<12).map { video("m\(String(format: "%02d", $0))", recent - Double($0) * 90_000, bytes: 150_000_000) }
        let first = SmartGrouper.groups(in: snapshot(huge + mid), now: now, calendar: calendar).first { $0.kind == .largeVideos }
        XCTAssertEqual(first?.records.count, 6)
        let second = SmartGrouper.groups(in: snapshot(Array(huge.prefix(2)) + mid), now: now, calendar: calendar).first { $0.kind == .largeVideos }
        XCTAssertEqual(second?.records.count, 10)
        XCTAssertEqual(second?.records.first?.displayBytes, 600_000_000, "Largest first.")
    }

    func testOldVideosLeaveOutFavoritesAlbumsAndRecentOnes() {
        let old = now.timeIntervalSince1970 - 3 * 365 * 86_400
        let top = (0..<10).map { video("t\($0)", now.timeIntervalSince1970 - Double($0 + 1) * 90_000, bytes: 400_000_000) }
        let items = top + [video("keep", old, bytes: 200_000_000), video("fav", old + 90_000, bytes: 200_000_000, favorite: true),
                           video("album", old + 180_000, bytes: 200_000_000, albums: ["1"]),
                           video("recent", now.timeIntervalSince1970 - 100, bytes: 200_000_000),
                           video("small", old + 270_000, bytes: 50_000_000)]
        let group = SmartGrouper.groups(in: snapshot(items), now: now, calendar: calendar).first { $0.kind == .oldVideos }
        XCTAssertEqual(group?.records.map(\.id), ["keep"])
    }

    func testICloudOriginalsCanBeArchivedButEditedAndOtherFormatsCannot() {
        var cloud = AssetRecord(id: "c", filename: "c.HEIC", mediaType: PHAssetMediaType.image.rawValue, favorite: false,
                                createdAt: now, resources: [], issue: "Original resource is not available locally.")
        XCTAssertFalse(SmartGrouper.canArchive(cloud))
        cloud.cloudBytes = 5_000_000
        XCTAssertTrue(SmartGrouper.canArchive(cloud))
        let edited = AssetRecord(id: "e", filename: "e.HEIC", mediaType: PHAssetMediaType.image.rawValue, favorite: false, createdAt: now,
                                 resources: [ResourceFingerprint(type: 1, digest: "a", bytes: 1), ResourceFingerprint(type: 5, digest: "b", bytes: 1)],
                                 issue: nil)
        XCTAssertFalse(SmartGrouper.canArchive(edited))
        XCTAssertFalse(SmartGrouper.canArchive(photo("p", 0, name: "p.png")))
        XCTAssertFalse(SmartGrouper.canArchive(photo("n", 0, name: "no-extension")))
    }

    func testFiftyThousandItemsGroupQuickly() {
        let items = (0..<50_000).map { photo("p\(String(format: "%05d", $0))", 1_500_000_000 + Double($0) * 1_700, at: $0 % 7 == 0 ? away : home) }
        let start = Date()
        _ = SmartGrouper.groups(in: snapshot(items), now: now, calendar: calendar)
        XCTAssertLessThan(Date().timeIntervalSince(start), 20)
    }
}
