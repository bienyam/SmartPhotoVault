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

    /// After Pro lapses the Check-ins screen shows what runs (monthly, on the saved day of the month),
    /// while the saved Pro choice stays put for when Pro comes back.
    func testLapsedProShowsMonthlyAndKeepsTheSavedChoice() {
        var settings = CheckInSettings()
        settings.frequency = .weekly
        settings.dayOfMonth = 15
        let shown = settings.effective(pro: false)
        XCTAssertEqual(shown.frequency, .monthly)
        XCTAssertEqual(shown.dayOfMonth, 15)
        XCTAssertEqual(CheckInPlan.components(for: shown)?.day, 15)
        XCTAssertEqual(settings.frequency, .weekly)
        XCTAssertEqual(settings.effective(pro: true).frequency, .weekly)
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

    // MARK: Long videos (free, 1.0.2)

    private func video(_ id: String, at recorded: Date, minutes: Double, gb: Double? = nil,
                       favorite: Bool = false) -> LongVideoCandidate {
        LongVideoCandidate(id: id, recorded: recorded, seconds: minutes * 60,
                           bytes: gb.map { Int64(($0 * 1_000).rounded()) * 1_000_000 }, favorite: favorite)
    }

    func testLongVideoAlertIsFreeAndWantsNotifications() {
        var settings = CheckInSettings()
        XCTAssertFalse(settings.longVideoOn)
        settings.longVideoOn = true
        XCTAssertTrue(settings.effective(pro: false).longVideoOn)
        XCTAssertTrue(settings.effective(pro: false).wantsNotifications)
    }

    func testLongVideoFirstRunOnlyStartsTheClock() {
        var settings = CheckInSettings()
        settings.longVideoOn = true
        let now = date(2026, 12, 3, 9)
        let old = video("old", at: date(2026, 12, 1), minutes: 60, gb: 4)
        let result = LongVideoAlerts.evaluate([old], settings: settings, state: CheckInAlertState(), now: now)
        XCTAssertNil(result.alert)
        XCTAssertEqual(result.state.longVideoSince, now)
    }

    func testLongVideoTellsOnceAboutANewLongVideo() {
        var settings = CheckInSettings()
        settings.longVideoOn = true
        settings.longVideoMinutes = 10
        var state = CheckInAlertState()
        state.longVideoSince = date(2026, 12, 3, 8)
        let now = date(2026, 12, 3, 20)
        let pocket = video("pocket", at: date(2026, 12, 3, 12), minutes: 42, gb: 3.1)
        let first = LongVideoAlerts.evaluate([pocket], settings: settings, state: state, now: now)
        XCTAssertEqual(first.alert, .longVideo(seconds: 42 * 60, bytes: 3_100_000_000))
        XCTAssertEqual(first.alert?.identifier, "checkin-alert-longvideo")
        XCTAssertTrue(first.alert?.body.contains("42-minute") ?? false)
        XCTAssertTrue(first.alert?.body.contains("Nothing is removed unless you choose") ?? false)
        XCTAssertEqual(first.state.longVideoSince, now)

        // The same video is never mentioned again, even if Photos still returns it.
        var again = first.state
        again.longVideoSince = date(2026, 12, 3, 8)
        XCTAssertNil(LongVideoAlerts.evaluate([pocket], settings: settings, state: again, now: now).alert)
    }

    func testLongVideoSkipsShortOldAndFavoriteVideos() {
        var settings = CheckInSettings()
        settings.longVideoOn = true
        settings.longVideoMinutes = 10
        var state = CheckInAlertState()
        state.longVideoSince = date(2026, 12, 3, 8)
        let now = date(2026, 12, 3, 20)
        let videos = [
            video("short", at: date(2026, 12, 3, 12), minutes: 9),
            video("before", at: date(2026, 12, 3, 7), minutes: 50),
            video("loved", at: date(2026, 12, 3, 13), minutes: 50, favorite: true),
        ]
        XCTAssertNil(LongVideoAlerts.evaluate(videos, settings: settings, state: state, now: now).alert)
    }

    func testLongVideosAreSummedIntoOneNotification() {
        var settings = CheckInSettings()
        settings.longVideoOn = true
        var state = CheckInAlertState()
        state.longVideoSince = date(2026, 12, 3, 8)
        let now = date(2026, 12, 3, 20)
        let videos = [video("a", at: date(2026, 12, 3, 10), minutes: 15, gb: 1),
                      video("b", at: date(2026, 12, 3, 11), minutes: 70, gb: 2)]
        let result = LongVideoAlerts.evaluate(videos, settings: settings, state: state, now: now)
        XCTAssertEqual(result.alert, .longVideos(count: 2, bytes: 3_000_000_000))
        XCTAssertEqual(result.state.longVideoTold, ["a", "b"])
    }

    func testTurningLongVideosOffResetsTheClock() {
        var state = CheckInAlertState()
        state.longVideoSince = date(2026, 12, 3, 8)
        let result = LongVideoAlerts.evaluate([], settings: CheckInSettings(), state: state, now: date(2026, 12, 3, 20))
        XCTAssertNil(result.alert)
        XCTAssertNil(result.state.longVideoSince)
    }

    func testLongVideoLengthWording() {
        XCTAssertEqual(LongVideoAlerts.length(42 * 60), "42-minute")
        XCTAssertEqual(LongVideoAlerts.length(60 * 60), "1-hour")
        XCTAssertEqual(LongVideoAlerts.length(65 * 60), "1-hour 5-minute")
    }

    /// Settings and alert state saved by 1.0.1 have no long-video keys. They must load with every
    /// saved choice intact, not fall back to defaults.
    func testSettingsAndStateSavedBeforeLongVideosStillLoad() throws {
        let oldSettings = #"{"frequency":"weekly","hour":8,"minute":30,"weekday":3,"dayOfMonth":5,"lowSpaceOn":true,"lowSpaceGB":5,"junkGrowthOn":true,"junkGrowthGB":3,"newPhotosOn":true,"newPhotos":500,"calendarOn":true,"daysBefore":7,"tidyAfter":false}"#
        let settings = try JSONDecoder().decode(CheckInSettings.self, from: Data(oldSettings.utf8))
        XCTAssertEqual(settings.frequency, .weekly)
        XCTAssertEqual(settings.hour, 8)
        XCTAssertEqual(settings.minute, 30)
        XCTAssertEqual(settings.weekday, 3)
        XCTAssertEqual(settings.dayOfMonth, 5)
        XCTAssertTrue(settings.lowSpaceOn)
        XCTAssertEqual(settings.lowSpaceGB, 5)
        XCTAssertTrue(settings.junkGrowthOn)
        XCTAssertEqual(settings.junkGrowthGB, 3)
        XCTAssertTrue(settings.newPhotosOn)
        XCTAssertEqual(settings.newPhotos, 500)
        XCTAssertTrue(settings.calendarOn)
        XCTAssertEqual(settings.daysBefore, 7)
        XCTAssertFalse(settings.tidyAfter)
        XCTAssertFalse(settings.longVideoOn)
        XCTAssertEqual(settings.longVideoMinutes, 10)

        let oldState = #"{"lowSpaceArmed":false,"junkBaseline":42,"libraryBaseline":7}"#
        let state = try JSONDecoder().decode(CheckInAlertState.self, from: Data(oldState.utf8))
        XCTAssertFalse(state.lowSpaceArmed)
        XCTAssertEqual(state.junkBaseline, 42)
        XCTAssertEqual(state.libraryBaseline, 7)
        XCTAssertNil(state.longVideoSince)
        XCTAssertEqual(state.longVideoTold, [])

        // And a round trip keeps the new keys.
        var withVideo = settings
        withVideo.longVideoOn = true
        withVideo.longVideoMinutes = 30
        let decoded = try JSONDecoder().decode(CheckInSettings.self, from: JSONEncoder().encode(withVideo))
        XCTAssertEqual(decoded, withVideo)
    }
}
