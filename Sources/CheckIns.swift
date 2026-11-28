import Foundation

/// How often TidyAway looks at storage and sends a check-in. Free: monthly. Pro: also daily and weekly.
enum CheckInFrequency: String, Codable, CaseIterable, Identifiable {
    case off, daily, weekly, monthly
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Off"
        case .daily: "Daily"
        case .weekly: "Weekly"
        case .monthly: "Monthly"
        }
    }
    var needsPro: Bool { self == .daily || self == .weekly }
}

/// Everything the Check-ins screen sets. Kept on this iPhone only.
struct CheckInSettings: Codable, Equatable {
    var frequency = CheckInFrequency.off
    var hour = 19
    var minute = 0
    /// 1 is Sunday, as in `Calendar`.
    var weekday = 1
    /// 1 to 28, so every month has the day.
    var dayOfMonth = 1

    var lowSpaceOn = false
    var lowSpaceGB = 10
    var junkGrowthOn = false
    var junkGrowthGB = 2
    var newPhotosOn = false
    var newPhotos = 200

    var calendarOn = false
    var daysBefore = 3
    var tidyAfter = true

    /// What actually runs. Without Pro: the monthly reminder only, nothing else.
    func effective(pro: Bool) -> CheckInSettings {
        guard !pro else { return self }
        var free = self
        if frequency.needsPro { free.frequency = .monthly }
        free.lowSpaceOn = false
        free.junkGrowthOn = false
        free.newPhotosOn = false
        free.calendarOn = false
        return free
    }

    /// True when anything would ever send a notification.
    var wantsNotifications: Bool {
        frequency != .off || lowSpaceOn || junkGrowthOn || newPhotosOn || calendarOn
    }

    static let lowSpaceChoices = [2, 5, 10, 15, 20, 30, 50]
    static let junkChoices = [1, 2, 3, 5, 10]
    static let newPhotoChoices = [50, 100, 200, 300, 500, 1000]
    static let daysBeforeChoices = [1, 2, 3, 5, 7]
}

/// When the repeating reminder fires.
enum CheckInPlan {
    /// The date parts for a repeating calendar trigger. Nil when check-ins are off.
    static func components(for settings: CheckInSettings) -> DateComponents? {
        var parts = DateComponents()
        parts.hour = settings.hour
        parts.minute = settings.minute
        switch settings.frequency {
        case .off: return nil
        case .daily: break
        case .weekly: parts.weekday = min(max(settings.weekday, 1), 7)
        case .monthly: parts.day = min(max(settings.dayOfMonth, 1), 28)
        }
        return parts
    }

    /// The next reminder after `date`. Nil when off.
    static func next(after date: Date, settings: CheckInSettings, calendar: Calendar = .current) -> Date? {
        guard let parts = components(for: settings) else { return nil }
        return calendar.nextDate(after: date, matching: parts, matchingPolicy: .nextTime)
    }

    /// The most recent reminder time at or before `date`, so a check-in that came due while the app
    /// was closed is caught up on the next open.
    static func previous(before date: Date, settings: CheckInSettings, calendar: Calendar = .current) -> Date? {
        guard let parts = components(for: settings) else { return nil }
        return calendar.nextDate(after: date, matching: parts, matchingPolicy: .nextTime, direction: .backward)
    }

    /// True when a scheduled check-in came due since the last one was recorded.
    static func isDue(now: Date, last: Date?, settings: CheckInSettings, calendar: Calendar = .current) -> Bool {
        guard let due = previous(before: now, settings: settings, calendar: calendar) else { return false }
        guard let last else { return true }
        return last < due
    }
}

/// One look at storage: what the system says is free, and what the last check found.
struct CheckInReading: Codable, Equatable {
    var date: Date
    var freeBytes: Int64
    var totalBytes: Int64
    /// What the last check on this iPhone found that can be cleared. Nil before any check.
    var junkBytes: Int64?
    /// Photos and videos in the library. Nil without Photos access.
    var libraryCount: Int?
    /// Free up groups by id: how many items and how much space.
    var groups: [String: CheckInTally] = [:]
    /// Space only the Pro smart picks could add, kept out of `junkBytes` on a free plan. Nil in
    /// readings saved before 1.0.2.
    var proJunkBytes: Int64? = nil
}

struct CheckInTally: Codable, Equatable {
    var count: Int
    var bytes: Int64
}

/// What the alerts last saw, so each one fires once per crossing, not on every check.
struct CheckInAlertState: Codable, Equatable {
    /// False after a low-space alert, until free space climbs back above the line.
    var lowSpaceArmed = true
    /// Junk size when the last junk alert fired (or the lowest seen since).
    var junkBaseline: Int64?
    /// Library size when the last new-photos alert fired, or at the last check-in.
    var libraryBaseline: Int?
}

enum CheckInAlert: Equatable {
    case lowSpace(free: Int64)
    case junkGrew(junk: Int64, by: Int64)
    case newPhotos(count: Int)

    var identifier: String {
        switch self {
        case .lowSpace: "checkin-alert-low"
        case .junkGrew: "checkin-alert-junk"
        case .newPhotos: "checkin-alert-photos"
        }
    }

    var title: String {
        switch self {
        case .lowSpace: "Space alert"
        case .junkGrew: "More to clear"
        case .newPhotos: "Lots of new photos"
        }
    }

    var body: String {
        switch self {
        case .lowSpace(let free):
            "Only \(free.fileSize) left. Open TidyAway to see what's taking the space."
        case .junkGrew(let junk, let by):
            "\(junk.fileSize) is ready to clear, up \(by.fileSize) since last time. Nothing is removed until you choose."
        case .newPhotos(let count):
            "\(count.formatted()) new photos and videos since your last check-in. TidyAway can find the look-alikes and blurry ones."
        }
    }
}

enum CheckInAlerts {
    static let gigabyte: Int64 = 1_000_000_000
    /// Free space must climb this far above the line before the low-space alert can fire again.
    static let rearmMargin: Int64 = 1_000_000_000

    /// Alerts to send for this reading, and the state to keep. Each alert fires once per crossing.
    static func evaluate(_ reading: CheckInReading, settings: CheckInSettings,
                         state: CheckInAlertState) -> (alerts: [CheckInAlert], state: CheckInAlertState) {
        var state = state
        var alerts: [CheckInAlert] = []

        let line = Int64(settings.lowSpaceGB) * gigabyte
        if settings.lowSpaceOn, reading.totalBytes > 0 {
            if reading.freeBytes < line {
                if state.lowSpaceArmed {
                    alerts.append(.lowSpace(free: reading.freeBytes))
                    state.lowSpaceArmed = false
                }
            } else if reading.freeBytes >= line + rearmMargin {
                state.lowSpaceArmed = true
            }
        } else {
            state.lowSpaceArmed = true
        }

        if let junk = reading.junkBytes {
            if let base = state.junkBaseline {
                let step = Int64(settings.junkGrowthGB) * gigabyte
                if settings.junkGrowthOn, step > 0, junk - base >= step {
                    alerts.append(.junkGrew(junk: junk, by: junk - base))
                    state.junkBaseline = junk
                } else if junk < base {
                    // Cleared some: measure growth from the new, lower level.
                    state.junkBaseline = junk
                }
            } else {
                state.junkBaseline = junk
            }
        }

        if let count = reading.libraryCount {
            if let base = state.libraryBaseline {
                if settings.newPhotosOn, count - base >= settings.newPhotos {
                    alerts.append(.newPhotos(count: count - base))
                    state.libraryBaseline = count
                } else if count < base {
                    state.libraryBaseline = count
                }
            } else {
                state.libraryBaseline = count
            }
        }
        return (alerts, state)
    }
}

/// The text of the repeating reminder. Generic until a check has numbers, then the real ones.
enum CheckInText {
    static func title(_ frequency: CheckInFrequency) -> String {
        switch frequency {
        case .daily: "Daily check-in"
        case .weekly: "Weekly check-in"
        default: "Monthly check-in"
        }
    }

    static func body(latest: CheckInReading?, previous: CheckInReading?) -> String {
        guard let latest else { return "See what's taking space on your \(Device.name) and what's new since last time." }
        var parts: [String] = []
        if let junk = latest.junkBytes, junk > 0 {
            parts.append("\(junk.fileSize) ready to clear.")
        }
        var free = "\(latest.freeBytes.fileSize) free"
        if let previous {
            let change = latest.freeBytes - previous.freeBytes
            if abs(change) >= 500_000_000 {
                free += change < 0 ? " (down \((-change).fileSize) since last time)" : " (up \(change.fileSize) since last time)"
            }
        }
        parts.append(free + ".")
        parts.append("Tap to see what changed.")
        return parts.joined(separator: " ")
    }
}

/// A calendar event, reduced to what the reminders need. The title is used only in notifications on this iPhone.
struct CheckInEvent: Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let allDay: Bool
    /// From a calendar the person didn't make, such as Birthdays from Contacts or a public holiday calendar.
    var subscribed = false
}

/// A notification planned for a date.
struct PlannedNote: Equatable {
    let id: String
    let date: Date
    let title: String
    let body: String
}

/// Picks the events worth a reminder and plans one note before and one after each.
enum EventPicker {
    static let horizon: TimeInterval = 14 * 86_400
    static let keywords: Set<String> = ["trip", "flight", "vacation", "holiday", "wedding", "birthday", "party",
                                        "graduation", "concert", "game", "festival"]
    /// iOS keeps 64 pending notifications. The reminder and alerts need a few; events get the rest, with room to spare.
    static let maxNotes = 40
    /// A typical photo, for "room for about N photos".
    static let photoBytes: Int64 = 3_500_000

    static func matchesKeyword(_ title: String) -> Bool {
        let words = title.lowercased().split { !$0.isLetter }.map(String.init)
        return words.contains { word in
            keywords.contains(word) || (word.hasSuffix("s") && keywords.contains(String(word.dropLast())))
        }
    }

    static func isBig(_ event: CheckInEvent, calendar: Calendar = .current) -> Bool {
        if matchesKeyword(event.title) { return true }
        // Holidays and contacts' birthdays come from calendars nobody made for this; only keywords count there.
        if event.subscribed { return false }
        if event.allDay { return true }
        if event.end.timeIntervalSince(event.start) >= 86_400 { return true }
        return !calendar.isDate(event.start, inSameDayAs: event.end.addingTimeInterval(-1))
    }

    /// Big events starting within the next 14 days, soonest first.
    static func pick(_ events: [CheckInEvent], now: Date, calendar: Calendar = .current) -> [CheckInEvent] {
        events
            .filter { $0.start > now && $0.start <= now.addingTimeInterval(horizon) && isBig($0, calendar: calendar) }
            .sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }

    static func photosThatFit(free: Int64) -> Int { Int(max(0, free) / photoBytes) }

    /// One reminder before each event and, if wanted, one after. Never more than `maxNotes`.
    static func notes(for events: [CheckInEvent], settings: CheckInSettings, now: Date, freeBytes: Int64?,
                      junkBytes: Int64?, calendar: Calendar = .current) -> [PlannedNote] {
        var notes: [PlannedNote] = []
        for event in pick(events, now: now, calendar: calendar) {
            let key = stableKey(event)
            if let day = calendar.date(byAdding: .day, value: -settings.daysBefore, to: calendar.startOfDay(for: event.start)),
               let when = calendar.date(bySettingHour: settings.hour, minute: settings.minute, second: 0, of: day),
               when > now, when < event.start {
                var body = "\(event.title) is \(relative(event.start, from: when, calendar: calendar))."
                if let freeBytes {
                    body += " You have room for about \(photosThatFit(free: freeBytes).formatted()) photos."
                }
                if let junkBytes, junkBytes > 0 {
                    body += " Clear \(junkBytes.fileSize) to make room for about \(photosThatFit(free: junkBytes).formatted()) more."
                }
                notes.append(PlannedNote(id: "checkin-event-before-\(key)", date: when, title: "Before \(event.title)", body: body))
            }
            if settings.tidyAfter,
               let day = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: event.end.addingTimeInterval(-1))),
               let when = calendar.date(bySettingHour: settings.hour, minute: settings.minute, second: 0, of: day),
               when > now {
                notes.append(PlannedNote(id: "checkin-event-after-\(key)", date: when, title: "After \(event.title)",
                                         body: "Took lots of photos? TidyAway can find the look-alikes and blurry ones from \(event.title). Best shots are kept."))
            }
        }
        return Array(notes.sorted { ($0.date, $0.id) < ($1.date, $1.id) }.prefix(maxNotes))
    }

    static func relative(_ date: Date, from: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: from), to: calendar.startOfDay(for: date)).day ?? 0
        switch days {
        case ..<1: return "today"
        case 1: return "tomorrow"
        default: return "in \(days) days"
        }
    }

    /// Short and stable across runs, so re-planning replaces a note instead of adding another.
    static func stableKey(_ event: CheckInEvent) -> String {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in "\(event.id)|\(Int(event.start.timeIntervalSince1970))".utf8 {
            hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
        return String(hash, radix: 36)
    }
}

/// Settings, alert state and the last check-ins, in this iPhone's app storage.
struct CheckInStore {
    var defaults: UserDefaults = .standard
    static let historyLimit = 12

    private enum Key {
        static let settings = "checkins.settings"
        static let state = "checkins.alertState"
        static let history = "checkins.history"
        static let latestJunk = "checkins.latestJunk"
        static let pro = "checkins.proSeen"
    }

    var settings: CheckInSettings {
        get { read(Key.settings) ?? CheckInSettings() }
        nonmutating set { write(newValue, Key.settings) }
    }

    var alertState: CheckInAlertState {
        get { read(Key.state) ?? CheckInAlertState() }
        nonmutating set { write(newValue, Key.state) }
    }

    /// Recorded check-ins, oldest first.
    var history: [CheckInReading] {
        get { read(Key.history) ?? [] }
        nonmutating set { write(Array(newValue.suffix(Self.historyLimit)), Key.history) }
    }

    /// What the last check on this iPhone found, for check-ins that run in the background.
    var latestJunk: CheckInReading? {
        get { read(Key.latestJunk) }
        nonmutating set { write(newValue, Key.latestJunk) }
    }

    /// Pro as last seen with the app open, so background runs follow the same plan.
    var proSeen: Bool {
        get { defaults.bool(forKey: Key.pro) }
        nonmutating set { defaults.set(newValue, forKey: Key.pro) }
    }

    func record(_ reading: CheckInReading) {
        history = history + [reading]
    }

    private func read<T: Decodable>(_ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T?, _ key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}
