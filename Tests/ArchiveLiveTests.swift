import XCTest
@testable import SmartPhotoVault

final class ArchiveLiveTests: XCTestCase {
    func testLiveTotalsCountBytesAndDownloads() {
        let live = ArchiveLive()
        live.wrote(1_000)
        live.wrote(500)
        live.downloading("a", 0.2)
        live.downloading("b", 0.6)
        XCTAssertEqual(live.now.written, 1_500)
        XCTAssertEqual(live.now.downloading, 2)
        XCTAssertEqual(live.now.fraction, 0.4, accuracy: 0.0001)
        live.downloading("a", nil)
        XCTAssertEqual(live.now.downloading, 1, "A finished item stops counting as downloading.")
        live.reset()
        XCTAssertEqual(live.now.written, 0)
        XCTAssertEqual(live.now.downloading, 0)
    }

    func testActivityStartsFreshAndStallLimitIsMinutesNotSeconds() {
        let activity = ArchiveActivity()
        XCTAssertLessThan(activity.silentFor, 1)
        XCTAssertGreaterThanOrEqual(ArchiveActivity.stallLimit, 120, "Slow iCloud queues must not be cut off too early.")
        XCTAssertLessThan(ArchiveActivity.stallLimit, 600, "A stuck item must give up well before the old 10-minute wait.")
    }
}

final class ArchiveLiveUploadTests: XCTestCase {
    func testUploadedBytesAreCountedAndReset() {
        let live = ArchiveLive()
        live.uploaded(10 * 1024 * 1024)
        live.uploaded(5)
        XCTAssertEqual(live.uploadedBytes, 10 * 1024 * 1024 + 5)
        live.reset()
        XCTAssertEqual(live.uploadedBytes, 0)
    }
}

final class ArchiveActivityProgressTests: XCTestCase {
    func testRepeatedZeroPercentIsNotProgressButRealProgressIs() throws {
        let activity = ArchiveActivity()
        Thread.sleep(forTimeInterval: 0.3)
        activity.progressed(0)
        activity.progressed(0)
        XCTAssertGreaterThan(activity.silentFor, 0.25, "Photos repeating 0% must not keep a stuck copy alive.")
        activity.progressed(0.1)
        XCTAssertLessThan(activity.silentFor, 0.2, "A download that moves forward counts as activity.")
        XCTAssertFalse(activity.gotData)
        activity.received()
        XCTAssertTrue(activity.gotData)
    }

    func testTheFirstWayGivesUpBeforeTheSecondWayIsTried() {
        XCTAssertLessThan(ArchiveActivity.firstTryLimit, ArchiveActivity.stallLimit)
    }
}
