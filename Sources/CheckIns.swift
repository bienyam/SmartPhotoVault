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

    /// Free (1.0.2): tell me about a new long video, such as one recorded by accident in a pocket.
    var longVideoOn = false
    var longVideoMinutes = 10

    /// What actually runs. Without Pro: the monthly reminder and the long-video alert, nothing else.
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
        frequency != .off || lowSpaceOn || junkGrowthOn || newPhotosOn || calendarOn || longVideoOn
    }

    static let longVideoChoices = [5, 10, 15, 30, 60]
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
    /// Long-video alert: only videos recorded after this are looked at. Nil until the alert first runs.
    var longVideoSince: Date?
    /// Long videos already told about, newest last, so each is mentioned once.
    var longVideoTold: [String] = []
}

/// A video the long-video alert might mention. Read from Photos; nothing here is ever changed.
struct LongVideoCandidate: Equatable {
    let id: String
    let recorded: Date
    let seconds: TimeInterval
    /// Nil when Photos doesn't report a size.
    let bytes: Int64?
    let favorite: Bool
}

/// Long videos: tells you once about a new video over the length you chose, like an hour recorded in a pocket.
/// It only notices and tells; any removal happens on screen with your sign-off and Apple's confirmation.
enum LongVideoAlerts {
    static let toldLimit = 200

    static func evaluate(_ videos: [LongVideoCandidate], settings: CheckInSettings, state: CheckInAlertState,
                         now: Date) -> (alert: CheckInAlert?, state: CheckInAlertState) {
        var state = state
        guard settings.longVideoOn else {
            // Off: start from "now" the next time it's switched on, never from old videos.
            state.longVideoSince = nil
            return (nil, state)
        }
        guard let since = state.longVideoSince else {
            state.longVideoSince = now
            return (nil, state)
        }
        let minimum = TimeInterval(max(1, settings.longVideoMinutes) * 60)
        let told = Set(state.longVideoTold)
        let fresh = videos
            .filter { $0.recorded > since && $0.recorded <= now && $0.seconds >= minimum && !$0.favorite && !told.contains($0.id) }
            .sorted { ($0.recorded, $0.id) < ($1.recorded, $1.id) }
        state.longVideoSince = now
        guard !fresh.isEmpty else { return (nil, state) }
        state.longVideoTold = Array((state.longVideoTold + fresh.map(\.id)).suffix(toldLimit))
        if fresh.count == 1, let video = fresh.first {
            return (.longVideo(seconds: video.seconds, bytes: video.bytes), state)
        }
        let known = fresh.compactMap(\.bytes)
        return (.longVideos(count: fresh.count, bytes: known.isEmpty ? nil : known.reduce(0, +)), state)
    }

    /// "42-minute", "1-hour 5-minute" style length for the notification.
    static func length(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(max(1, minutes))-minute" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours)-hour" : "\(hours)-hour \(rest)-minute"
    }
}

enum CheckInAlert: Equatable {
    case lowSpace(free: Int64)
    case junkGrew(junk: Int64, by: Int64)
    case newPhotos(count: Int)
    case longVideo(seconds: TimeInterval, bytes: Int64?)
    case longVideos(count: Int, bytes: Int64?)

    var identifier: String {
        switch self {
        case .lowSpace: "checkin-alert-low"
        case .junkGrew: "checkin-alert-junk"
        case .newPhotos: "checkin-alert-photos"
        case .longVideo, .longVideos: "checkin-alert-longvideo"
        }
    }

    var title: String {
        switch self {
        case .lowSpace: "Space alert"
        case .junkGrew: "More to clear"
        case .newPhotos: "Lots of new photos"
        case .longVideo: "Long video recorded"
        case .longVideos: "Long videos recorded"
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
        case .longVideo(let seconds, let bytes):
            "A new \(LongVideoAlerts.length(seconds)) video\(bytes.map { " (\($0.fileSize))" } ?? "") is taking up space. "
                + "If it was recorded by accident, like in a pocket, you can review it in TidyAway. Nothing is removed unless you choose."
        case .longVideos(let count, let bytes):
            "\(count) new long videos\(bytes.map { " (\($0.fileSize))" } ?? "") are taking up space. "
                + "If any were recorded by accident, you can review them in TidyAway. Nothing is removed unless you choose."
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

extension CheckInSettings {
    /// Settings saved by an older version lack the newer keys; those take their defaults instead of
    /// the whole saved choice being thrown away.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CheckInSettings()
        frequency = try c.decodeIfPresent(CheckInFrequency.self, forKey: .frequency) ?? d.frequency
        hour = try c.decodeIfPresent(Int.self, forKey: .hour) ?? d.hour
        minute = try c.decodeIfPresent(Int.self, forKey: .minute) ?? d.minute
        weekday = try c.decodeIfPresent(Int.self, forKey: .weekday) ?? d.weekday
        dayOfMonth = try c.decodeIfPresent(Int.self, forKey: .dayOfMonth) ?? d.dayOfMonth
        lowSpaceOn = try c.decodeIfPresent(Bool.self, forKey: .lowSpaceOn) ?? d.lowSpaceOn
        lowSpaceGB = try c.decodeIfPresent(Int.self, forKey: .lowSpaceGB) ?? d.lowSpaceGB
        junkGrowthOn = try c.decodeIfPresent(Bool.self, forKey: .junkGrowthOn) ?? d.junkGrowthOn
        junkGrowthGB = try c.decodeIfPresent(Int.self, forKey: .junkGrowthGB) ?? d.junkGrowthGB
        newPhotosOn = try c.decodeIfPresent(Bool.self, forKey: .newPhotosOn) ?? d.newPhotosOn
        newPhotos = try c.decodeIfPresent(Int.self, forKey: .newPhotos) ?? d.newPhotos
        calendarOn = try c.decodeIfPresent(Bool.self, forKey: .calendarOn) ?? d.calendarOn
        daysBefore = try c.decodeIfPresent(Int.self, forKey: .daysBefore) ?? d.daysBefore
        tidyAfter = try c.decodeIfPresent(Bool.self, forKey: .tidyAfter) ?? d.tidyAfter
        longVideoOn = try c.decodeIfPresent(Bool.self, forKey: .longVideoOn) ?? d.longVideoOn
        longVideoMinutes = try c.decodeIfPresent(Int.self, forKey: .longVideoMinutes) ?? d.longVideoMinutes
    }
}

extension CheckInAlertState {
    /// State saved by an older version lacks the newer keys; those start fresh, the rest is kept.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lowSpaceArmed = try c.decodeIfPresent(Bool.self, forKey: .lowSpaceArmed) ?? true
        junkBaseline = try c.decodeIfPresent(Int64.self, forKey: .junkBaseline)
        libraryBaseline = try c.decodeIfPresent(Int.self, forKey: .libraryBaseline)
        longVideoSince = try c.decodeIfPresent(Date.self, forKey: .longVideoSince)
        longVideoTold = try c.decodeIfPresent([String].self, forKey: .longVideoTold) ?? []
    }
}
