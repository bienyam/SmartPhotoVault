import XCTest
@testable import SmartPhotoVault

final class CheckInTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private let gb: Int64 = 1_000_000_000

    // MARK: Schedule

    func testOffHasNoReminder() {
        XCTAssertNil(CheckInPlan.components(for: CheckInSettings()))
        XCTAssertNil(CheckInPlan.next(after: .now, settings: CheckInSettings(), calendar: calendar))
    }

    func testNextFireDates() {
        var settings = CheckInSettings()
        settings.hour = 19
        settings.minute = 0
        let now = date(2026, 12, 3, 9, 41) // a Thursday

        settings.frequency = .daily
        XCTAssertEqual(CheckInPlan.next(after: now, settings: settings, calendar: calendar), date(2026, 12, 3, 19))

        settings.frequency = .weekly
        settings.weekday = 1 // Sunday
        XCTAssertEqual(CheckInPlan.next(after: now, settings: settings, calendar: calendar), date(2026, 12, 6, 19))

        settings.frequency = .monthly
        settings.dayOfMonth = 1
        XCTAssertEqual(CheckInPlan.next(after: now, settings: settings, calendar: calendar), date(2027, 1, 1, 19))
    }

    func testMonthlyDayIsKeptToOneThroughTwentyEight() {
        var settings = CheckInSettings()
        settings.frequency = .monthly
        settings.dayOfMonth = 31
        XCTAssertEqual(CheckInPlan.components(for: settings)?.day, 28)
    }

    func testDueWhenAReminderTimePassedSinceTheLastCheckIn() {
        var settings = CheckInSettings()
        settings.frequency = .monthly
        settings.dayOfMonth = 1
        let now = date(2026, 12, 3)
        XCTAssertTrue(CheckInPlan.isDue(now: now, last: nil, settings: settings, calendar: calendar))
        XCTAssertTrue(CheckInPlan.isDue(now: now, last: date(2026, 11, 20), settings: settings, calendar: calendar))
        XCTAssertFalse(CheckInPlan.isDue(now: now, last: date(2026, 12, 2), settings: settings, calendar: calendar))
        XCTAssertFalse(CheckInPlan.isDue(now: now, last: nil, settings: CheckInSettings(), calendar: calendar))
    }

    // MARK: Free and Pro

    func testFreeKeepsOnlyTheMonthlyReminder() {
        var settings = CheckInSettings()
        settings.frequency = .weekly
        settings.lowSpaceOn = true
        settings.junkGrowthOn = true
        settings.newPhotosOn = true
        settings.calendarOn = true
        let free = settings.effective(pro: false)
        XCTAssertEqual(free.frequency, .monthly)
        XCTAssertFalse(free.lowSpaceOn || free.junkGrowthOn || free.newPhotosOn || free.calendarOn)
        XCTAssertEqual(settings.effective(pro: true), settings)
        XCTAssertTrue(CheckInFrequency.daily.needsPro)
        XCTAssertTrue(CheckInFrequency.weekly.needsPro)
        XCTAssertFalse(CheckInFrequency.monthly.needsPro)
    }

    // MARK: Alerts fire once per crossing

    private func reading(free: Int64, junk: Int64? = nil, library: Int? = nil) -> CheckInReading {
        CheckInReading(date: .now, freeBytes: free, totalBytes: 128 * gb, junkBytes: junk, libraryCount: library)
    }

    func testLowSpaceFiresOnceUntilSpaceComesBack() {
        var settings = CheckInSettings()
        settings.lowSpaceOn = true
        settings.lowSpaceGB = 10
        var state = CheckInAlertState()

        var result = CheckInAlerts.evaluate(reading(free: 9 * gb), settings: settings, state: state)
        XCTAssertEqual(result.alerts, [.lowSpace(free: 9 * gb)])
        state = result.state

        result = CheckInAlerts.evaluate(reading(free: 8 * gb), settings: settings, state: state)
        XCTAssertTrue(result.alerts.isEmpty, "Still low: no second alert.")
        state = result.state

        // Just above the line is not enough to re-arm.
        result = CheckInAlerts.evaluate(reading(free: 10 * gb + 500_000_000), settings: settings, state: state)
        state = result.state
        result = CheckInAlerts.evaluate(reading(free: 9 * gb), settings: settings, state: state)
        XCTAssertTrue(result.alerts.isEmpty)
        state = result.state

        result = CheckInAlerts.evaluate(reading(free: 12 * gb), settings: settings, state: state)
        state = result.state
        result = CheckInAlerts.evaluate(reading(free: 9 * gb), settings: settings, state: state)
        XCTAssertEqual(result.alerts.count, 1, "Back above the line, then low again: alert again.")
    }

    func testJunkGrowthMeasuresFromTheLastAlertOrTheLowestLevel() {
        var settings = CheckInSettings()
        settings.junkGrowthOn = true
        settings.junkGrowthGB = 2
        var result = CheckInAlerts.evaluate(reading(free: 50 * gb, junk: 3 * gb), settings: settings, state: CheckInAlertState())
        XCTAssertTrue(result.alerts.isEmpty, "The first reading sets the starting point.")

        result = CheckInAlerts.evaluate(reading(free: 50 * gb, junk: 4 * gb), settings: settings, state: result.state)
        XCTAssertTrue(result.alerts.isEmpty)

        result = CheckInAlerts.evaluate(reading(free: 50 * gb, junk: 5 * gb), settings: settings, state: result.state)
        XCTAssertEqual(result.alerts, [.junkGrew(junk: 5 * gb, by: 2 * gb)])

        result = CheckInAlerts.evaluate(reading(free: 50 * gb, junk: 6 * gb), settings: settings, state: result.state)
        XCTAssertTrue(result.alerts.isEmpty, "Growth counts again from the last alert.")

        // Cleared down to 1 GB, then grew back to 3 GB: that is 2 GB of new junk.
        result = CheckInAlerts.evaluate(reading(free: 50 * gb, junk: 1 * gb), settings: settings, state: result.state)
        result = CheckInAlerts.evaluate(reading(free: 50 * gb, junk: 3 * gb), settings: settings, state: result.state)
        XCTAssertEqual(result.alerts.count, 1)
    }

    func testNewPhotosAlertOncePerBatch() {
        var settings = CheckInSettings()
        settings.newPhotosOn = true
        settings.newPhotos = 200
        var result = CheckInAlerts.evaluate(reading(free: 50 * gb, library: 1_000), settings: settings, state: CheckInAlertState())
        XCTAssertTrue(result.alerts.isEmpty)
        result = CheckInAlerts.evaluate(reading(free: 50 * gb, library: 1_150), settings: settings, state: result.state)
        XCTAssertTrue(result.alerts.isEmpty)
        result = CheckInAlerts.evaluate(reading(free: 50 * gb, library: 1_230), settings: settings, state: result.state)
        XCTAssertEqual(result.alerts, [.newPhotos(count: 230)])
        result = CheckInAlerts.evaluate(reading(free: 50 * gb, library: 1_300), settings: settings, state: result.state)
        XCTAssertTrue(result.alerts.isEmpty)
    }

    func testAlertsOffSendNothing() {
        let settings = CheckInSettings()
        let result = CheckInAlerts.evaluate(reading(free: 1 * gb, junk: 50 * gb, library: 9_000), settings: settings,
                                            state: CheckInAlertState(lowSpaceArmed: true, junkBaseline: 0, libraryBaseline: 0))
        XCTAssertTrue(result.alerts.isEmpty)
    }

    // MARK: Reminder text

    func testReminderTextUsesRealNumbersWhenThereAreSome() {
        XCTAssertTrue(CheckInText.body(latest: nil, previous: nil).contains("what's new"))
        let before = reading(free: 45 * gb, junk: 2 * gb)
        let now = reading(free: 41 * gb, junk: 3_200_000_000)
        let text = CheckInText.body(latest: now, previous: before)
        XCTAssertTrue(text.contains("ready to clear"))
        XCTAssertTrue(text.contains("down"))
    }

    // MARK: Calendar

    private func event(_ title: String, start: Date, hours: Double = 2, allDay: Bool = false, subscribed: Bool = false) -> CheckInEvent {
        CheckInEvent(id: title, title: title, start: start, end: start.addingTimeInterval(hours * 3_600), allDay: allDay, subscribed: subscribed)
    }

    func testKeywordsMatchWholeWordsAndPlurals() {
        XCTAssertTrue(EventPicker.matchesKeyword("Sam & Ana's Wedding"))
        XCTAssertTrue(EventPicker.matchesKeyword("Flight to Lisbon"))
        XCTAssertTrue(EventPicker.matchesKeyword("Mia's birthday party"))
        XCTAssertTrue(EventPicker.matchesKeyword("Playoff games"))
        XCTAssertFalse(EventPicker.matchesKeyword("Dentist"))
        XCTAssertFalse(EventPicker.matchesKeyword("Gamestop return"), "Only whole words count.")
        XCTAssertFalse(EventPicker.matchesKeyword("Strip mall errands"), "trip inside another word is not a trip.")
    }

    func testPicksBigEventsInTheNextTwoWeeks() {
        let now = date(2026, 12, 3, 9)
        let events = [
            event("Dentist", start: date(2026, 12, 4, 10)),
            event("Wedding", start: date(2026, 12, 6, 15)),
            event("Team offsite", start: date(2026, 12, 8, 9), hours: 30),
            event("Day off", start: date(2026, 12, 9, 0), hours: 24, allDay: true),
            event("Concert", start: date(2026, 12, 30, 20)),
            event("Columbus Day", start: date(2026, 12, 10, 0), hours: 24, allDay: true, subscribed: true),
            event("Mom's Birthday", start: date(2026, 12, 11, 0), hours: 24, allDay: true, subscribed: true),
            event("Past party", start: date(2026, 12, 1, 20))
        ]
        let picked = EventPicker.pick(events, now: now, calendar: calendar).map(\.title)
        XCTAssertEqual(picked, ["Wedding", "Team offsite", "Day off", "Mom's Birthday"])
    }

    func testNotesBeforeAndAfter() {
        var settings = CheckInSettings()
        settings.daysBefore = 3
        settings.hour = 19
        let now = date(2026, 12, 1, 9)
        let wedding = event("Wedding", start: date(2026, 12, 6, 15), hours: 6)
        let notes = EventPicker.notes(for: [wedding], settings: settings, now: now, freeBytes: 10 * gb, junkBytes: 2 * gb, calendar: calendar)
        XCTAssertEqual(notes.count, 2)
        XCTAssertEqual(notes[0].date, date(2026, 12, 3, 19))
        XCTAssertTrue(notes[0].body.contains("room for about"))
        XCTAssertEqual(notes[1].date, date(2026, 12, 7, 19))

        settings.tidyAfter = false
        XCTAssertEqual(EventPicker.notes(for: [wedding], settings: settings, now: now, freeBytes: nil, junkBytes: nil, calendar: calendar).count, 1)
    }

    func testBeforeNoteIsSkippedWhenItsTimeHasPassed() {
        var settings = CheckInSettings()
        settings.daysBefore = 3
        let now = date(2026, 12, 5, 9)
        let wedding = event("Wedding", start: date(2026, 12, 6, 15))
        let notes = EventPicker.notes(for: [wedding], settings: settings, now: now, freeBytes: nil, junkBytes: nil, calendar: calendar)
        XCTAssertEqual(notes.map { $0.id.hasPrefix("checkin-event-after-") }, [true])
    }

    func testNotesStayWellUnderTheSystemLimit() {
        let now = date(2026, 12, 1, 9)
        let many = (0..<60).map { index in
            event("Party \(index)", start: now.addingTimeInterval(Double(index + 1) * 4 * 3_600))
        }
        let notes = EventPicker.notes(for: many, settings: CheckInSettings(), now: now, freeBytes: nil, junkBytes: nil, calendar: calendar)
        XCTAssertLessThanOrEqual(notes.count, EventPicker.maxNotes)
        XCTAssertLessThan(EventPicker.maxNotes + 4, 64, "The reminder and three alerts must still fit.")
        XCTAssertEqual(Set(notes.map(\.id)).count, notes.count)
    }

    func testEventKeysAreStable() {
        let first = event("Wedding", start: date(2026, 12, 6, 15))
        XCTAssertEqual(EventPicker.stableKey(first), EventPicker.stableKey(first))
        XCTAssertNotEqual(EventPicker.stableKey(first), EventPicker.stableKey(event("Wedding", start: date(2026, 12, 7, 15))))
    }

    // MARK: Storage

    func testHistoryKeepsTheLastTwelve() {
        let defaults = UserDefaults(suiteName: "CheckInTests-\(UUID().uuidString)")!
        let store = CheckInStore(defaults: defaults)
        for index in 0..<15 {
            store.record(CheckInReading(date: Date(timeIntervalSince1970: Double(index)), freeBytes: Int64(index), totalBytes: 100))
        }
        XCTAssertEqual(store.history.count, CheckInStore.historyLimit)
        XCTAssertEqual(store.history.first?.freeBytes, 3)
        var settings = CheckInSettings()
        settings.frequency = .weekly
        store.settings = settings
        XCTAssertEqual(store.settings.frequency, .weekly)
    }
}
