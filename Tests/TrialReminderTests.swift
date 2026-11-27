import XCTest
import UserNotifications
@testable import SmartPhotoVault

/// The reminder before a free trial ends (D2): when it is planned, and when it is not.
final class TrialReminderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 24 * 3_600

    func testRemindsTwoDaysBeforeTheTrialEnds() {
        let ends = now.addingTimeInterval(7 * day)
        let trial = TrialReminder.Trial(ends: ends, willRenew: true)
        XCTAssertEqual(TrialReminder.decision(for: trial, now: now), .schedule(at: ends.addingTimeInterval(-2 * day)))
    }

    func testNoReminderWithoutATrial() {
        XCTAssertEqual(TrialReminder.decision(for: nil, now: now), .none)
    }

    func testNoReminderOnceTheTrialIsCancelled() {
        let trial = TrialReminder.Trial(ends: now.addingTimeInterval(7 * day), willRenew: false)
        XCTAssertEqual(TrialReminder.decision(for: trial, now: now), .none)
    }

    func testNoReminderOnceTheTrialHasEnded() {
        let trial = TrialReminder.Trial(ends: now.addingTimeInterval(-day), willRenew: true)
        XCTAssertEqual(TrialReminder.decision(for: trial, now: now), .none)
    }

    func testNoReminderWhenTheTwoDayMarkHasPassed() {
        let trial = TrialReminder.Trial(ends: now.addingTimeInterval(day), willRenew: true)
        XCTAssertEqual(TrialReminder.decision(for: trial, now: now), .none)
    }

    func testTheReminderNamesTheDateAndHowToCancel() {
        let ends = now.addingTimeInterval(7 * day)
        let body = TrialReminder.body(ends: ends)
        XCTAssertTrue(body.contains(TrialReminder.day(ends)))
        XCTAssertTrue(body.hasPrefix("Your TidyAway Pro free trial ends on "))
        XCTAssertTrue(body.contains("Settings › your name › Subscriptions"))
        XCTAssertFalse(body.lowercased().contains("we'll remind"))
        // True even if the trial was already cancelled: no promise that it will renew.
        XCTAssertTrue(body.contains("To stop it renewing, check Settings"))
        XCTAssertFalse(body.contains("Nothing to do"))
        XCTAssertTrue(TrialReminder.dateLine(ends: ends).contains(TrialReminder.day(ends)))
    }

    func testOnlyAllowedNotificationsCount() {
        XCTAssertTrue(TrialReminder.allowed(.authorized))
        XCTAssertTrue(TrialReminder.allowed(.provisional))
        XCTAssertFalse(TrialReminder.allowed(.denied))
        XCTAssertFalse(TrialReminder.allowed(.notDetermined))
    }
}
