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

    // MARK: - Bursts stay review-only (A4)

    /// A burst that would fit every smart group still never appears in one: bursts are cleared only
    /// from By type › Bursts, where they are review-only.
    func testABurstNeverAppearsInAnySmartGroup() {
        func burst(_ base: AssetRecord, _ group: String = "B1") -> AssetRecord {
            var record = base
            record.burstID = group
            return record
        }
        var assets: [AssetRecord] = []
        var insights: [String: PhotoInsight] = [:]
        let screen = CleanupGrouper.screenLabels.first ?? "monitor"
        // For each group: three plain photos so the group exists, plus burst frames that also qualify.
        let kinds: [(String, PhotoInsight)] = [
            ("blur", insight("", sharp: 10)), ("dark", insight("", light: 5)),
            ("acc", insight("", sharp: 20, light: 20)), ("paper", insight("", labels: ["receipt"])),
            ("screen", insight("", labels: [screen]))
        ]
        for (name, template) in kinds {
            for index in 0..<5 {
                let id = "\(name)\(index)"
                let record = photo(id)
                assets.append(index < 3 ? record : burst(record, "B-\(name)"))
                let value = PhotoInsight(id: id, labels: template.labels, sharpness: template.sharpness,
                                     closeFace: false, sameAs: nil, brightness: template.brightness, anyFace: false)
                insights[id] = value
            }
        }
        // Look-alikes: a plain chain and a burst chain, seconds apart.
        let chain = (0..<4).map { photo("look\($0)", secondsAgo: 60 - Double($0)) }
        let burstChain = (0..<4).map { burst(photo("bl\($0)", secondsAgo: 30 - Double($0)), "B-look") }
        for (index, record) in chain.enumerated() {
            insights[record.id] = insight(record.id, sharp: 300 + Double(index), sameAs: index == 0 ? nil : chain[index - 1].id)
        }
        for (index, record) in burstChain.enumerated() {
            insights[record.id] = insight(record.id, sharp: 300 + Double(index), sameAs: index == 0 ? nil : burstChain[index - 1].id)
        }
        assets += chain + burstChain
        // Old screenshots: a burst can't be a screenshot in Photos, but the rule holds anyway.
        let shots = (0..<4).map { photo("shot\($0)", screenshot: true) }
        assets += shots.prefix(3) + [burst(shots[3], "B-shot")]

        let bursts = Set(assets.filter { $0.burstID != nil }.map(\.id))
        XCTAssertFalse(bursts.isEmpty)
        let groups = CleanupGrouper.groups(in: snapshot(assets), insights: insights, facts: [:], now: now)
        XCTAssertFalse(groups.isEmpty, "The plain photos still make groups.")
        for group in groups {
            XCTAssertTrue(bursts.isDisjoint(with: group.items.map(\.id)), "No burst in \(group.id).")
            XCTAssertTrue(bursts.isDisjoint(with: group.sets.flatMap { [$0.keep] + $0.extras }.map(\.id)), "No burst in \(group.id) sets.")
        }
        if let pick = CleanupGrouper.suggestion(from: groups) {
            XCTAssertTrue(bursts.isDisjoint(with: pick.items.map(\.id)), "No burst in Suggested for you.")
        }
        let sets = CleanupGrouper.keepSets(in: assets, insights: insights, facts: [:], includeBursts: false)
        XCTAssertFalse(sets.isEmpty, "The plain look-alikes still make a set for Best shots.")
        XCTAssertTrue(bursts.isDisjoint(with: sets.flatMap { [$0.keep] + $0.extras }.map(\.id)), "No burst in Best shots.")
        XCTAssertTrue(bursts.isDisjoint(with: SmartGrouper.series(in: assets, insights: insights, includeBursts: false)
            .flatMap { $0 }.map(\.id)))
    }

    /// A4 covers only the lists that offer items for deletion. Archive's look-alike group is as shipped:
    /// bursts that look alike are still offered to move out.
    func testArchiveLookAlikeGroupStillIncludesBursts() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let shots = (0..<7).map { index -> AssetRecord in
            var record = AssetRecord(id: "b\(index)", filename: "b\(index).heic", mediaType: PHAssetMediaType.image.rawValue,
                                     favorite: false, createdAt: now.addingTimeInterval(-100 + Double(index)),
                                     resources: [ResourceFingerprint(type: PHAssetResourceType.photo.rawValue, digest: "b\(index)", bytes: 1_000)],
                                     issue: nil, isScreenshot: false, albumIDs: [])
            record.burstID = "B-archive"
            return record
        }
        var insights: [String: PhotoInsight] = [:]
        for (index, shot) in shots.enumerated() {
            var value = PhotoInsight(id: shot.id)
            value.sharpness = shot.id == "b3" ? 900 : 100
            value.brightness = 120
            value.sameAs = index == 0 ? nil : shots[index - 1].id
            insights[shot.id] = value
        }
        let snapshot = ScanSnapshot(date: now, limitedAccess: false, includedCloudDownloads: false, assets: shots)
        let archive = SmartGrouper.groups(in: snapshot, insights: insights, facts: [:], now: now).first { $0.kind == .sameShots }
        XCTAssertNotNil(archive, "Archive still groups look-alike bursts.")
        XCTAssertEqual(Set(archive?.records.map(\.id) ?? []), Set(shots.map(\.id)).subtracting(["b3"]))
        XCTAssertEqual(archive?.sets.first?.keep.id, "b3")
        XCTAssertEqual(SmartGrouper.series(in: shots, insights: insights).first?.count, 7, "Default series is unchanged.")
        // The deletion lists built from the same photos hold none of them.
        let cleanup = CleanupGrouper.groups(in: snapshot, insights: insights, facts: [:], now: now)
        XCTAssertTrue(cleanup.allSatisfy { $0.items.isEmpty || $0.items.allSatisfy { $0.burstID == nil } })
        XCTAssertFalse(cleanup.contains { $0.id == "look-alike" })
        XCTAssertTrue(CleanupGrouper.keepSets(in: shots, insights: insights, facts: [:], includeBursts: false).isEmpty,
                      "Best shots offers no bursts.")
    }

    func testBurstsAreStillReviewOnlyInByType() {
        XCTAssertFalse(CleanCategory.bursts.allowsRemoval, "By type › Bursts is unchanged.")
    }
}
