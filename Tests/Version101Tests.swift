import SwiftUI
import XCTest
@testable import SmartPhotoVault

/// The rules 1.0.1 rests on: the Storage Score, who keeps what for free, and the look setting.
final class Version101Tests: XCTestCase {
    private let gb: Int64 = 1_000_000_000

    private func emptyDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "v101-\(name)"
        let store = UserDefaults(suiteName: suite)!
        store.removePersistentDomain(forName: suite)
        return store
    }

    // MARK: Storage Score

    func testScoreIsFreeOverTotalTimesFour() {
        // The mockup's iPhone: 16 GB free of 128 GB is 12.5% free, and 12.5 × 4 = 50.
        let score = StorageScore(free: 16 * gb, total: 128 * gb)
        XCTAssertEqual(score.value, 50)
        XCTAssertEqual(score.band, .c)
        XCTAssertEqual(score.band.name, "Getting full")
        XCTAssertEqual(score.freePercent, "12.5%")
    }

    func testScoreIsCappedAtOneHundred() {
        XCTAssertEqual(StorageScore.value(free: 32 * gb, total: 128 * gb), 100, "25% free scores 100.")
        XCTAssertEqual(StorageScore.value(free: 100 * gb, total: 128 * gb), 100, "More than 25% free still scores 100.")
        XCTAssertEqual(StorageScore.value(free: 128 * gb, total: 128 * gb), 100)
        XCTAssertEqual(StorageScore.value(free: 500 * gb, total: 128 * gb), 100, "Free can never push the score past 100.")
    }

    func testScoreNeverGoesBelowZeroOrDividesByZero() {
        XCTAssertEqual(StorageScore.value(free: 0, total: 128 * gb), 0)
        XCTAssertEqual(StorageScore.value(free: -5, total: 128 * gb), 0)
        XCTAssertEqual(StorageScore.value(free: 10 * gb, total: 0), 0)
        XCTAssertEqual(StorageScore(free: 10 * gb, total: 0).band, .e)
    }

    func testBandEdges() {
        let total: Int64 = 1_000
        // Free space in tenths of a percent of a 1,000-byte phone.
        let cases: [(free: Int64, score: Int, band: StorageScore.Band)] = [
            (0, 0, .e), (49, 19, .e),
            (50, 20, .d), (99, 39, .d),
            (100, 40, .c), (149, 59, .c),
            (150, 60, .b), (199, 79, .b),
            (200, 80, .a), (250, 100, .a), (1_000, 100, .a)
        ]
        for item in cases {
            let score = StorageScore(free: item.free, total: total)
            XCTAssertEqual(score.value, item.score, "free \(item.free)")
            XCTAssertEqual(score.band, item.band, "free \(item.free)")
        }
    }

    func testBandsCoverEveryScoreOnce() {
        for value in 0...100 {
            let matches = StorageScore.Band.allCases.filter { $0.scores.contains(value) }
            XCTAssertEqual(matches.count, 1, "score \(value)")
            XCTAssertEqual(StorageScore.Band.of(score: value), matches.first)
        }
        XCTAssertEqual(StorageScore.Band.allCases.map(\.name),
                       ["Healthy", "Comfortable", "Getting full", "Tight", "Nearly full"])
    }

    func testScoreRoundsDownSoUnderTwentyPercentIsNeverAnA() {
        // 19.99% free is 79.96 before rounding.
        XCTAssertEqual(StorageScore.value(free: 1_999, total: 10_000), 79)
        XCTAssertEqual(StorageScore(free: 1_999, total: 10_000).band, .b)
    }

    func testStorageSplitWorksOutTheMiddleBySubtraction() {
        let storage = DeviceStorage(available: 16 * gb, total: 128 * gb)
        let split = StorageSplit(storage: storage, photos: 48 * gb)
        XCTAssertEqual(split.photos, 48 * gb)
        XCTAssertEqual(split.rest, 64 * gb)
        XCTAssertEqual(split.free, 16 * gb)
        XCTAssertEqual(split.photos + split.rest + split.free, split.total)
        XCTAssertEqual(split.fraction(split.free), 0.125, accuracy: 0.0001)
        // Photos can never be shown as more than what is used.
        let over = StorageSplit(storage: storage, photos: 500 * gb)
        XCTAssertEqual(over.photos, 112 * gb)
        XCTAssertEqual(over.rest, 0)
        // Before a check, photos aren't known and everything used sits in the middle.
        XCTAssertEqual(StorageSplit(storage: storage, photos: nil).rest, 112 * gb)
    }

    // MARK: Free and Pro

    func testProOpensEverything() {
        for feature in ProFeature.allCases {
            XCTAssertTrue(ProGate.allows(feature, pro: true, grandfathered: false), feature.rawValue)
            XCTAssertTrue(ProGate.allows(feature, pro: true, grandfathered: true), feature.rawValue)
        }
    }

    func testWithoutProEveryProFeatureIsLocked() {
        for feature in ProFeature.allCases {
            XCTAssertFalse(ProGate.allows(feature, pro: false, grandfathered: false), feature.rawValue)
        }
    }

    func testGrandfatheredPeopleKeepSmartPicksAndNothingElse() {
        XCTAssertTrue(ProGate.allows(.smartPicks, pro: false, grandfathered: true))
        for feature in ProFeature.allCases where feature != .smartPicks {
            XCTAssertFalse(ProGate.allows(feature, pro: false, grandfathered: true), feature.rawValue)
        }
    }

    func testTheByTypeListsAreNeverProFeatures() {
        XCTAssertEqual(ProGate.freeRows, ["row-duplicates", "row-videos", "row-screenshots", "row-more"])
        XCTAssertEqual(ProStore.freeArchiveBytes, 5_000_000_000, "The free archive allowance stays 5 GB.")
    }

    func testFreeCheckInsKeepOnlyTheMonthlyReminder() {
        var settings = CheckInSettings()
        settings.frequency = .weekly
        settings.lowSpaceOn = true
        settings.calendarOn = true
        let free = settings.effective(pro: false)
        XCTAssertEqual(free.frequency, .monthly)
        XCTAssertFalse(free.lowSpaceOn)
        XCTAssertFalse(free.calendarOn)
        XCTAssertEqual(settings.effective(pro: true), settings)
        XCTAssertFalse(CheckInFrequency.monthly.needsPro)
        XCTAssertTrue(CheckInFrequency.daily.needsPro)
    }

    // MARK: Grandfathering

    func testAppStoreRecordOfVersionOneGrandfathers() {
        XCTAssertTrue(Grandfather.startedOnVersionOne(originalAppVersion: "1.0", production: true))
        XCTAssertTrue(Grandfather.startedOnVersionOne(originalAppVersion: "184.1", production: true),
                      "On iPhone, Apple's record holds the build number of the first install.")
        XCTAssertTrue(Grandfather.startedOnVersionOne(originalAppVersion: "\(Grandfather.lastVersionOneBuild).1", production: true))
    }

    func testLaterInstallsAreNotGrandfathered() {
        XCTAssertFalse(Grandfather.startedOnVersionOne(originalAppVersion: "\(Grandfather.lastVersionOneBuild + 1).1", production: true))
        XCTAssertFalse(Grandfather.startedOnVersionOne(originalAppVersion: "1.0.1", production: true))
        XCTAssertFalse(Grandfather.startedOnVersionOne(originalAppVersion: "260.1", production: true))
        XCTAssertFalse(Grandfather.startedOnVersionOne(originalAppVersion: "", production: true))
        XCTAssertFalse(Grandfather.startedOnVersionOne(originalAppVersion: "abc", production: true))
    }

    func testTheTestEnvironmentRecordProvesNothing() {
        // Apple reports "1.0" for every TestFlight and sandbox install.
        XCTAssertFalse(Grandfather.startedOnVersionOne(originalAppVersion: "1.0", production: false))
    }

    func testEarlierDataAtFirstLaunchGrandfathersAndIsKept() {
        let store = emptyDefaults()
        XCTAssertFalse(Grandfather.isSet(in: store))
        XCTAssertTrue(Grandfather.noteFirstLaunch(hadEarlierData: true, store: store))
        XCTAssertTrue(Grandfather.isSet(in: store))
        // Later launches never take it away, whatever they find.
        XCTAssertTrue(Grandfather.noteFirstLaunch(hadEarlierData: false, store: store))
        XCTAssertTrue(Grandfather.note(originalAppVersion: "999.1", production: true, store: store))
    }

    func testAFreshInstallIsNotGrandfatheredLater() {
        let store = emptyDefaults()
        XCTAssertFalse(Grandfather.noteFirstLaunch(hadEarlierData: false, store: store))
        // By the second launch 1.0.1 has made its own data; that must not count as 1.0 data.
        XCTAssertFalse(Grandfather.noteFirstLaunch(hadEarlierData: true, store: store))
        XCTAssertFalse(Grandfather.isSet(in: store))
    }

    func testAppStoreRecordCanGrandfatherAfterAFreshStart() {
        let store = emptyDefaults()
        Grandfather.noteFirstLaunch(hadEarlierData: false, store: store)
        XCTAssertFalse(Grandfather.note(originalAppVersion: "1.0", production: false, store: store))
        XCTAssertTrue(Grandfather.note(originalAppVersion: "151.1", production: true, store: store),
                      "A reinstall is recognised from Apple's record.")
        XCTAssertTrue(Grandfather.isSet(in: store))
    }

    func testEarlierDataIsRecognisedFromTheWelcomeFlag() {
        let store = emptyDefaults()
        let nowhere = FileManager()
        // The app's own files may exist on the test device, so only the flag's effect is checked.
        store.set(true, forKey: "hasSeenWelcome")
        XCTAssertTrue(Grandfather.hasEarlierData(store: store, files: nowhere))
    }

    // MARK: Appearance

    func testAppearanceDefaultsToSameAsIPhone() {
        let store = emptyDefaults()
        XCTAssertEqual(AppearanceStore.load(from: store), .system)
        XCTAssertNil(AppearanceChoice.system.colorScheme)
        XCTAssertEqual(AppearanceChoice.system.title, "Same as iPhone")
    }

    func testAppearanceIsKept() {
        let store = emptyDefaults()
        for choice in AppearanceChoice.allCases {
            AppearanceStore.save(choice, to: store)
            XCTAssertEqual(AppearanceStore.load(from: store), choice)
            XCTAssertEqual(store.string(forKey: AppearanceStore.key), choice.rawValue)
        }
        XCTAssertEqual(AppearanceChoice.light.colorScheme, .light)
        XCTAssertEqual(AppearanceChoice.dark.colorScheme, .dark)
        XCTAssertEqual(AppearanceChoice.dark.interfaceStyle, .dark)
        XCTAssertEqual(AppearanceChoice.system.interfaceStyle, .unspecified)
    }

    func testAnUnknownSavedAppearanceFallsBackToTheIPhone() {
        let store = emptyDefaults()
        store.set("sepia", forKey: AppearanceStore.key)
        XCTAssertEqual(AppearanceStore.load(from: store), .system)
    }

    // MARK: More tab

    func testTheTipOfTheWeekChangesEachWeekAndComesRound() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 12, day: 2, hour: 12))!
        let weeks = (0..<Tip.allCases.count).map { Tip.ofTheWeek(start.addingTimeInterval(Double($0) * 7 * 86_400), calendar: calendar) }
        XCTAssertEqual(Set(weeks).count, Tip.allCases.count, "Each tip gets a week.")
        XCTAssertEqual(Tip.ofTheWeek(start, calendar: calendar), Tip.ofTheWeek(start.addingTimeInterval(86_400), calendar: calendar))
        XCTAssertEqual(Tip.allCases.map(\.identifier), ["guide-messages", "more-explainer", "more-optimize"],
                       "The tips keep the identifiers they shipped with.")
    }

    func testTheProPageListsWhatStaysFree() {
        let free = ProPlanLists.alwaysFree.map(\.text).joined(separator: " ").lowercased()
        for word in ["duplicates", "large videos", "screenshots", "5 gb", "destination", "get archived items back",
                     "activity", "preview", "favorites", "storage checkup", "monthly check-in"] {
            XCTAssertTrue(free.contains(word), "Always free should mention \(word)")
        }
        let paid = ProPlanLists.addedWithPro.map(\.text).joined(separator: " ").lowercased()
        for word in ["smart picks", "without a limit", "archive groups", "daily or weekly", "smart pro"] {
            XCTAssertTrue(paid.contains(word), "Added with Pro should mention \(word)")
        }
        XCTAssertFalse(free.contains("smart picks"))
    }

    // MARK: Free space trend

    func testTrendKeepsOnePointADay() {
        let store = emptyDefaults()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let day = calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 9))!
        FreeSpaceTrend.record(16 * gb, at: day, store: store, calendar: calendar)
        FreeSpaceTrend.record(18 * gb, at: day.addingTimeInterval(3_600), store: store, calendar: calendar)
        XCTAssertEqual(FreeSpaceTrend.points(store: store).map(\.freeBytes), [18 * gb], "The same day keeps the latest reading.")
        FreeSpaceTrend.record(25 * gb, at: day.addingTimeInterval(86_400 * 2), store: store, calendar: calendar)
        let points = FreeSpaceTrend.points(store: store)
        XCTAssertEqual(points.map(\.freeBytes), [18 * gb, 25 * gb])
        XCTAssertEqual(FreeSpaceTrend.heights(points), [0, 1])
        XCTAssertTrue(FreeSpaceTrend.summary(points)?.hasPrefix("Up ") ?? false)
        XCTAssertNil(FreeSpaceTrend.summary([points[0]]))
    }

    func testTrendIsCappedAndFlatLinesSitInTheMiddle() {
        let store = emptyDefaults()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for day in 0..<(FreeSpaceTrend.limit + 10) {
            FreeSpaceTrend.record(10 * gb, at: start.addingTimeInterval(Double(day) * 86_400), store: store)
        }
        let points = FreeSpaceTrend.points(store: store)
        XCTAssertEqual(points.count, FreeSpaceTrend.limit)
        XCTAssertEqual(Set(FreeSpaceTrend.heights(points)), [0.5])
        XCTAssertTrue(FreeSpaceTrend.heights([]).isEmpty)
        XCTAssertEqual(FreeSpaceTrend.summary(points)?.hasPrefix("About the same"), true)
    }
}
