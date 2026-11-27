import XCTest
import Photos
@testable import SmartPhotoVault

/// The Free up page's totals and the Storage Checkup's bookkeeping.
final class HomeAndCheckupTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let gb: Int64 = 1_000_000_000

    private func photo(_ id: String, digest: String? = nil, bytes: Int64 = 1_000, screenshot: Bool = false, favorite: Bool = false) -> AssetRecord {
        AssetRecord(id: id, filename: "\(id).heic", mediaType: PHAssetMediaType.image.rawValue, favorite: favorite,
                    createdAt: now.addingTimeInterval(-400 * 86_400),
                    resources: [ResourceFingerprint(type: PHAssetResourceType.photo.rawValue, digest: digest ?? id, bytes: bytes)],
                    issue: nil, isScreenshot: screenshot,
                    subtypes: screenshot ? PHAssetMediaSubtype.photoScreenshot.rawValue : 0, albumIDs: [])
    }

    private func video(_ id: String, bytes: Int64) -> AssetRecord {
        AssetRecord(id: id, filename: "\(id).mov", mediaType: PHAssetMediaType.video.rawValue, favorite: false,
                    createdAt: now.addingTimeInterval(-400 * 86_400),
                    resources: [ResourceFingerprint(type: PHAssetResourceType.video.rawValue, digest: id, bytes: bytes)],
                    issue: nil, isScreenshot: false, subtypes: 0, albumIDs: [])
    }

    private func rescue(_ assets: [AssetRecord]) -> RescueSummary {
        RescueSummary(snapshot: ScanSnapshot(date: now, limitedAccess: false, includedCloudDownloads: false, assets: assets))
    }

    // MARK: Totals

    func testTotalsCountEachItemOnceAcrossShelves() {
        // Two identical screenshots: the extra copy is both a duplicate and a screenshot.
        let first = photo("s1", digest: "same", bytes: 4_000, screenshot: true)
        let copy = photo("s2", digest: "same", bytes: 4_000, screenshot: true)
        let clip = video("v1", bytes: 50_000)
        let blurry = photo("p1", bytes: 2_000)
        let summary = rescue([first, copy, clip, blurry])
        let smart = [CleanupGroup(id: "blurry", tier: .safe, title: "Blurry photos", why: "Out of focus", info: "", items: [blurry])]
        let totals = TidyTotals.make(rescue: summary, smart: smart, archived: [], sets: [])
        XCTAssertEqual(totals.shelves[TidyRow.Shelf.safe.rawValue], 8_000, "Both screenshots, the duplicate counted once.")
        XCTAssertEqual(totals.shelves[TidyRow.Shelf.look.rawValue], 2_000)
        XCTAssertEqual(totals.shelves[TidyRow.Shelf.move.rawValue], 50_000)
        XCTAssertEqual(totals.total, 60_000)
    }

    func testAnItemOnTwoShelvesIsCountedOnceInTheTotal() {
        let shot = photo("s1", bytes: 3_000, screenshot: true)
        let summary = rescue([shot])
        // The same screenshot is also in a smart group.
        let smart = [CleanupGroup(id: "old-screenshots", tier: .probably, title: "Old screenshots", why: "", info: "", items: [shot])]
        let totals = TidyTotals.make(rescue: summary, smart: smart, archived: [], sets: [])
        XCTAssertEqual(totals.shelves[TidyRow.Shelf.safe.rawValue], 3_000)
        XCTAssertEqual(totals.shelves[TidyRow.Shelf.look.rawValue], 3_000)
        XCTAssertEqual(totals.total, 3_000, "The estimate never counts one photo twice.")
    }

    func testTotalsLeaveOutFavoritesAndKeptPhotos() {
        let favoriteShot = photo("s1", bytes: 5_000, screenshot: true, favorite: true)
        let shot = photo("s2", bytes: 1_000, screenshot: true)
        let keep = photo("k1", bytes: 7_000)
        let extra = photo("k2", bytes: 3_000)
        let favoriteBlurry = photo("b1", bytes: 9_000, favorite: true)
        let summary = rescue([favoriteShot, shot, keep, extra, favoriteBlurry])
        let set = KeepSet(keep: keep, extras: [extra], because: "the sharpest")
        // Even if a group were to hold a favorite or the kept photo, neither can be selected, so neither counts.
        let smart = [CleanupGroup(id: "look-alike", tier: .probably, title: "Look-alike shots", why: "", info: "",
                                  items: [keep, extra, favoriteBlurry], sets: [set])]
        let totals = TidyTotals.make(rescue: summary, smart: smart, archived: [], sets: [set])
        XCTAssertEqual(totals.shelves[TidyRow.Shelf.safe.rawValue], 1_000, "The favorite screenshot is never counted.")
        XCTAssertEqual(totals.shelves[TidyRow.Shelf.look.rawValue], 3_000, "Only the extra look-alike counts.")
        XCTAssertEqual(totals.total, 4_000, "The estimate matches what can actually be selected.")
    }

    func testDuplicatesListKeepsTheKeptCopyFirstInOrder() {
        let a = photo("a"), b = photo("b"), c = photo("c"), d = photo("d")
        XCTAssertEqual(DuplicateGroup.keptFirst([a, b, c, d], keep: "c").map(\.id), ["c", "a", "b", "d"])
        XCTAssertEqual(DuplicateGroup.keptFirst([a, b], keep: nil).map(\.id), ["a", "b"])
    }

    func testEmptyLibraryTotalsAreZero() {
        let totals = TidyTotals.make(rescue: rescue([]), smart: [], archived: [], sets: [])
        XCTAssertEqual(totals.total, 0)
    }

    // MARK: Free plan numbers (B6)

    private func planFixture() -> (RescueSummary, [CleanupGroup], [KeepSet]) {
        let shot = photo("s1", bytes: 3_000, screenshot: true)
        let clip = video("v1", bytes: 50_000)
        let blurry = photo("p1", bytes: 2_000)
        let keep = photo("k1", bytes: 7_000)
        let extra = photo("k2", bytes: 4_000)
        let summary = rescue([shot, clip, blurry, keep, extra])
        let set = KeepSet(keep: keep, extras: [extra], because: "the sharpest")
        // The screenshot is also an old screenshot: already counted for free, so never "more with Pro".
        let smart = [CleanupGroup(id: "blurry", tier: .safe, title: "Blurry photos", why: "", info: "", items: [blurry]),
                     CleanupGroup(id: "old-screenshots", tier: .probably, title: "Old screenshots", why: "", info: "", items: [shot])]
        return (summary, smart, [set])
    }

    func testFreePlanTotalCountsOnlyWhatFreeCanClear() {
        let (summary, smart, sets) = planFixture()
        let free = TidyTotals.make(rescue: summary, smart: smart, archived: [], sets: sets,
                                   allowsSmartPicks: false, allowsSmartPro: false)
        XCTAssertEqual(free.total, 53_000, "Screenshot and video only.")
        XCTAssertEqual(free.shelves[TidyRow.Shelf.look.rawValue], 0, "Smart picks and Best shots stay out of the shelf total.")
        XCTAssertEqual(free.proOnly, 6_000, "The blurry photo and the look-alike extra, each once.")
    }

    func testProAndGrandfatheredTotalsAreUnchanged() {
        let (summary, smart, sets) = planFixture()
        let today = TidyTotals.make(rescue: summary, smart: smart, archived: [], sets: sets)
        let pro = TidyTotals.make(rescue: summary, smart: smart, archived: [], sets: sets,
                                  allowsSmartPicks: true, allowsSmartPro: true)
        XCTAssertEqual(pro, today)
        XCTAssertEqual(pro.total, 59_000)
        XCTAssertEqual(pro.proOnly, 0)
        // Started on 1.0: smart picks are theirs, Best shots is still Smart Pro.
        let early = TidyTotals.make(rescue: summary, smart: smart, archived: [], sets: sets,
                                    allowsSmartPicks: true, allowsSmartPro: false)
        XCTAssertEqual(early.total, 55_000)
        XCTAssertEqual(early.proOnly, 4_000)
    }

    func testFreeCheckInSaysOnlyWhatFreeCanClear() {
        let (summary, smart, _) = planFixture()
        let free = CheckInRunner.tally(groups: smart, rescue: summary, allowsSmartPicks: false, now: now)
        let pro = CheckInRunner.tally(groups: smart, rescue: summary, allowsSmartPicks: true, now: now)
        XCTAssertEqual(free.junkBytes, summary.duplicateBytes, "No duplicates here, so nothing Free can clear is counted.")
        XCTAssertEqual(free.proJunkBytes, 5_000, "The smart picks, each item once.")
        XCTAssertEqual(pro.junkBytes, summary.duplicateBytes + 5_000)
        XCTAssertEqual(pro.proJunkBytes, 0)
        XCTAssertEqual(free.groups, pro.groups, "Every row is still listed; Pro rows carry the badge.")
        XCTAssertEqual(CheckInRunner.tally(groups: smart, rescue: summary, now: now), pro, "Default is today's Pro tally.")
        XCTAssertFalse(CheckInText.body(latest: CheckInReading(date: now, freeBytes: 0, totalBytes: 0, junkBytes: free.junkBytes,
                                                              libraryCount: nil), previous: nil).contains("ready to clear"),
                       "A free check-in with nothing Free can clear doesn't claim any.")
    }

    func testOldSavedReadingsStillDecode() throws {
        let old = #"{"date":0,"freeBytes":1,"totalBytes":2,"junkBytes":3,"groups":{}}"#
        let reading = try JSONDecoder().decode(CheckInReading.self, from: Data(old.utf8))
        XCTAssertEqual(reading.junkBytes, 3)
        XCTAssertNil(reading.proJunkBytes)
    }

    func testShelvesAreNamedAsApproved() {
        XCTAssertEqual(TidyRow.Shelf.allCases.map(\.title), ["Safe to clear", "Worth a look", "Move it, keep it"])
    }

    // MARK: Storage Checkup

    func testCheckupMeasuresEachStepAgainstTheLastReading() {
        var progress = CheckupProgress(free: 16 * gb, now: now)
        let steps = Checkup.steps
        XCTAssertEqual(progress.next, steps[0])
        progress.measured(steps[0], free: 21 * gb)
        XCTAssertEqual(progress.results[steps[0].id], 5 * gb)
        XCTAssertEqual(progress.next, steps[1])
        progress.measured(steps[1], free: 24 * gb)
        XCTAssertEqual(progress.results[steps[1].id], 3 * gb, "Each step is compared with the reading before it.")
        XCTAssertEqual(progress.gained(now: 24 * gb), 8 * gb)
        XCTAssertEqual(progress.doneCount, 2)
    }

    func testCheckupSaysNoChangeWhenSpaceDidNotRise() {
        var progress = CheckupProgress(free: 16 * gb, now: now)
        let step = Checkup.steps[0]
        progress.measured(step, free: 16 * gb + 1_000_000)
        XCTAssertEqual(progress.results[step.id], 0, "A megabyte is just iOS at work.")
        XCTAssertTrue(progress.isDone(step))
        XCTAssertNil(progress.gained(now: 16 * gb))
        XCTAssertNil(progress.gained(now: 10 * gb), "Less free space is never shown as a gain.")
        XCTAssertEqual(CheckupProgress.resultLine(0), "No change yet")
        XCTAssertTrue(CheckupProgress.resultLine(3 * gb).hasPrefix("Free space rose "))
    }

    func testSkippedStepsMoveOnAndCanBeDoneLater() {
        var progress = CheckupProgress(free: 16 * gb, now: now)
        let steps = Checkup.steps
        progress.skip(steps[0])
        XCTAssertEqual(progress.next, steps[1])
        XCTAssertFalse(progress.isDone(steps[0]))
        progress.measured(steps[0], free: 18 * gb)
        XCTAssertTrue(progress.isDone(steps[0]))
        XCTAssertFalse(progress.isSkipped(steps[0]))
    }

    func testCheckupIsKeptAndStartsFreshAfterADay() {
        let suite = "checkup-\(#function)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        XCTAssertNil(CheckupProgress.load(store: store, now: now))
        var progress = CheckupProgress(free: 16 * gb, now: now)
        progress.measured(Checkup.steps[0], free: 20 * gb)
        progress.save(store: store)
        XCTAssertEqual(CheckupProgress.load(store: store, now: now.addingTimeInterval(3_600)), progress)
        XCTAssertNil(CheckupProgress.load(store: store, now: now.addingTimeInterval(25 * 3_600)))
    }

    func testCheckupStepsGiveAPathAndNeverAskForARestart() {
        XCTAssertEqual(Checkup.steps.count, 7)
        XCTAssertEqual(Set(Checkup.steps.map(\.id)).count, 7)
        for step in Checkup.steps {
            XCTAssertTrue(step.path.contains("›"), "\(step.id) gives its path as text.")
            XCTAssertFalse(step.actions.isEmpty)
            let words = ([step.title, step.subtitle, step.path, step.caution] + step.actions).joined(separator: " ").lowercased()
            for banned in ["restart", "reboot", "power off", "prefs:", "app-settings", "junk", "boost", "cache cleaner"] {
                XCTAssertFalse(words.contains(banned), "\(step.id) must not say \(banned)")
            }
        }
    }
}
