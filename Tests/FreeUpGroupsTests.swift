import XCTest
import Photos
@testable import SmartPhotoVault

final class FreeUpGroupsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func photo(_ id: String, secondsAgo: Double = 400 * 86_400, favorite: Bool = false, screenshot: Bool = false) -> AssetRecord {
        AssetRecord(id: id, filename: "\(id).heic", mediaType: PHAssetMediaType.image.rawValue, favorite: favorite,
                    createdAt: now.addingTimeInterval(-secondsAgo),
                    resources: [ResourceFingerprint(type: PHAssetResourceType.photo.rawValue, digest: id, bytes: 1_000)],
                    issue: nil, isScreenshot: screenshot, albumIDs: [])
    }

    private func snapshot(_ assets: [AssetRecord]) -> ScanSnapshot {
        ScanSnapshot(date: now, limitedAccess: false, includedCloudDownloads: false, assets: assets)
    }

    private func insight(_ id: String, sharp: Double = 500, light: Double = 120, labels: [String] = [], sameAs: String? = nil) -> PhotoInsight {
        var value = PhotoInsight(id: id)
        value.sharpness = sharp
        value.brightness = light
        value.labels = labels
        value.sameAs = sameAs
        // Checked for faces, none found. Receipts & documents leaves a photo out until that is known.
        value.anyFace = false
        return value
    }

    // MARK: - Look-alikes keep one, never offered

    func testLookAlikeKeepsTheSharpestAndNeverOffersIt() {
        let a = photo("a", secondsAgo: 30), b = photo("b", secondsAgo: 29), c = photo("c", secondsAgo: 28), d = photo("d", secondsAgo: 27)
        let insights = ["a": insight("a", sharp: 300), "b": insight("b", sharp: 900, sameAs: "a"),
                        "c": insight("c", sharp: 200, sameAs: "b"), "d": insight("d", sharp: 250, sameAs: "c")]
        let groups = CleanupGrouper.groups(in: snapshot([a, b, c, d]), insights: insights, facts: [:], now: now)
        let look = groups.first { $0.id == "look-alike" }
        XCTAssertNotNil(look)
        XCTAssertEqual(look?.sets.first?.keep.id, "b", "The sharpest stays.")
        XCTAssertEqual(Set(look?.items.map(\.id) ?? []), ["a", "c", "d"])
        XCTAssertFalse(look?.items.contains { $0.id == "b" } ?? true, "The kept photo is never offered for removal.")
        XCTAssertEqual(look?.sets.first?.because, "the sharpest")
    }

    func testAFavoriteInASetIsTheOneKept() {
        let a = photo("a", secondsAgo: 30), b = photo("b", secondsAgo: 29, favorite: true), c = photo("c", secondsAgo: 28)
        let insights = ["a": insight("a", sharp: 900), "b": insight("b", sharp: 100, sameAs: "a"), "c": insight("c", sameAs: "b")]
        let sets = CleanupGrouper.keepSets(in: [a, b, c], insights: insights, facts: [:])
        XCTAssertEqual(sets.first?.keep.id, "b")
        XCTAssertEqual(sets.first?.because, "your favorite")
        XCTAssertFalse(sets.flatMap(\.extras).contains { $0.favorite })
    }

    // MARK: - Plain groups

    func testBlurryDarkAndAccidentalAreSeparateAndNeverFavorites() {
        let assets = (0..<4).map { photo("blur\($0)") } + (0..<4).map { photo("dark\($0)") }
            + (0..<4).map { photo("acc\($0)") } + [photo("favblur", favorite: true)]
        var insights: [String: PhotoInsight] = [:]
        for i in 0..<4 {
            insights["blur\(i)"] = insight("blur\(i)", sharp: 10, light: 120, labels: ["beach"])
            insights["dark\(i)"] = insight("dark\(i)", sharp: 5, light: 5)
            insights["acc\(i)"] = insight("acc\(i)", sharp: 60, light: 25)
        }
        insights["favblur"] = insight("favblur", sharp: 10)
        let groups = Dictionary(uniqueKeysWithValues: CleanupGrouper.groups(in: snapshot(assets), insights: insights, facts: [:], now: now).map { ($0.id, $0) })
        XCTAssertEqual(Set(groups["blurry"]?.items.map(\.id) ?? []), Set((0..<4).map { "blur\($0)" }))
        XCTAssertEqual(Set(groups["dark"]?.items.map(\.id) ?? []), Set((0..<4).map { "dark\($0)" }))
        XCTAssertEqual(Set(groups["accidental"]?.items.map(\.id) ?? []), Set((0..<4).map { "acc\($0)" }))
        let everything = groups.values.flatMap(\.items).map(\.id)
        XCTAssertFalse(everything.contains("favblur"), "Favorites are never in a smart group.")
        XCTAssertEqual(everything.count, Set(everything).count, "An item is in one group only.")
    }

    func testSharpWellLitPhotosAreLeftAlone() {
        let assets = (0..<5).map { photo("ok\($0)") }
        let insights = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, insight($0.id, sharp: 800, light: 130, labels: ["beach"])) })
        XCTAssertTrue(CleanupGrouper.groups(in: snapshot(assets), insights: insights, facts: [:], now: now).isEmpty)
    }

    func testOnlyOldScreenshotsAndOldReceipts() {
        let old = (0..<3).map { photo("os\($0)", secondsAgo: 40 * 86_400, screenshot: true) }
        let fresh = photo("ns", secondsAgo: 5 * 86_400, screenshot: true)
        let receipts = (0..<3).map { photo("r\($0)", secondsAgo: 120 * 86_400) }
        let newReceipt = photo("rn", secondsAgo: 10 * 86_400)
        var insights = Dictionary(uniqueKeysWithValues: receipts.map { ($0.id, insight($0.id, labels: ["receipt"])) })
        insights["rn"] = insight("rn", labels: ["receipt"])
        let groups = Dictionary(uniqueKeysWithValues: CleanupGrouper.groups(in: snapshot(old + [fresh] + receipts + [newReceipt]),
                                                                            insights: insights, facts: [:], now: now).map { ($0.id, $0) })
        XCTAssertEqual(Set(groups["old-screenshots"]?.items.map(\.id) ?? []), Set(old.map(\.id)))
        XCTAssertEqual(Set(groups["expired"]?.items.map(\.id) ?? []), Set(receipts.map(\.id)))
    }

    func testSuggestionCombinesWithoutRepeatsAndCarriesTheKeptSets() {
        let a = photo("a", secondsAgo: 30), b = photo("b", secondsAgo: 29), c = photo("c", secondsAgo: 28), d = photo("d", secondsAgo: 27)
        let blur = (0..<3).map { photo("blur\($0)") }
        var insights = ["a": insight("a", sharp: 900), "b": insight("b", sameAs: "a"), "c": insight("c", sameAs: "b"), "d": insight("d", sameAs: "c")]
        for item in blur { insights[item.id] = insight(item.id, sharp: 10) }
        let groups = CleanupGrouper.groups(in: snapshot([a, b, c, d] + blur), insights: insights, facts: [:], now: now)
        let pick = CleanupGrouper.suggestion(from: groups)
        XCTAssertNotNil(pick)
        XCTAssertEqual(pick?.items.count, 6)
        XCTAssertFalse(pick?.items.contains { $0.id == "a" } ?? true, "The kept photo is never in the suggestion.")
        XCTAssertEqual(pick?.sets.first?.keep.id, "a")
    }
}

final class ArchiveKeptPhotoTests: XCTestCase {
    func testArchiveLookAlikeGroupShowsTheKeptPhotoButNeverMovesIt() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func photo(_ id: String, _ seconds: Double) -> AssetRecord {
            AssetRecord(id: id, filename: "\(id).heic", mediaType: PHAssetMediaType.image.rawValue, favorite: false,
                        createdAt: now.addingTimeInterval(-seconds),
                        resources: [ResourceFingerprint(type: PHAssetResourceType.photo.rawValue, digest: id, bytes: 1_000)],
                        issue: nil, isScreenshot: false, albumIDs: [])
        }
        let shots = (0..<6).map { photo("s\($0)", 100 - Double($0)) }
        var insights: [String: PhotoInsight] = [:]
        for (index, shot) in shots.enumerated() {
            var value = PhotoInsight(id: shot.id)
            value.sharpness = shot.id == "s2" ? 900 : 100
            value.brightness = 120
            value.sameAs = index == 0 ? nil : shots[index - 1].id
            insights[shot.id] = value
        }
        let snapshot = ScanSnapshot(date: now, limitedAccess: false, includedCloudDownloads: false, assets: shots)
        let group = SmartGrouper.groups(in: snapshot, insights: insights, facts: [:], now: now).first { $0.kind == .sameShots }
        XCTAssertNotNil(group)
        XCTAssertEqual(group?.sets.first?.keep.id, "s2", "The sharpest stays and is shown.")
        XCTAssertFalse(group?.records.contains { $0.id == "s2" } ?? true, "The kept photo is never moved.")
        let parts = group.map { SkimPart.parts(of: $0) } ?? []
        XCTAssertEqual(parts.first?.keep?.id, "s2")
        XCTAssertFalse(parts.flatMap(\.records).contains { $0.id == "s2" })
    }
}
