import BackgroundTasks
import EventKit
import Photos
import SwiftUI
import UserNotifications

/// Runs check-ins: the repeating reminder, the space alerts and the calendar reminders.
/// It only reads and notifies. Nothing is ever deleted here; removing anything always happens
/// on screen, with the person's sign-off and Apple's confirmation.
@MainActor
final class CheckInCenter: NSObject, ObservableObject {
    static let shared = CheckInCenter()

    @Published var settings: CheckInSettings
    @Published private(set) var notificationsDenied = false
    @Published private(set) var calendarDenied = false
    /// Set when someone taps a check-in notification; the app then shows the report.
    @Published var showReport = false

    private let store = CheckInStore()
    /// UI tests with sample data never touch the system's notification or calendar prompts.
    private let demo = LaunchFlags.has("--demo")

    private override init() {
        settings = CheckInStore().settings
        super.init()
    }

    /// Called at launch, before launch finishes, so a tapped notification opens the report even
    /// from a cold start. Safe to call again.
    func start() {
        guard !demo else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// Saves a change from the Check-ins screen and plans everything again.
    func update(_ change: (inout CheckInSettings) -> Void, pro: Bool) async {
        var next = settings
        change(&next)
        let turningOnCalendar = next.calendarOn && !settings.calendarOn
        settings = next
        store.settings = next
        store.proSeen = pro
        if next.effective(pro: pro).wantsNotifications { await askForNotifications() }
        if turningOnCalendar {
            let allowed = await askForCalendar()
            if !allowed {
                settings.calendarOn = false
                store.settings = settings
            } else {
                try? InventoryStore.openDefault().log("Calendar reminders turned on. Events are read on this \(Device.name) only.")
            }
        }
        await catchUp(pro: pro)
    }

    /// Every time the app opens: the same look a background run takes, since iOS may not have run one.
    func catchUp(pro: Bool) async {
        store.proSeen = pro
        guard !demo else { return }
        await CheckInRunner.run(recount: false)
        CheckInBackground.schedule(settings: settings.effective(pro: pro))
        await refreshPermissionState()
    }

    /// The last check on this iPhone, recorded when Free up makes its groups.
    /// `allowsSmartPicks` is the plan's: without it the "ready to clear" number counts only what Free can clear.
    func noteCheck(groups: [CleanupGroup], rescue: RescueSummary, allowsSmartPicks: Bool) {
        guard !demo else { return }
        store.latestJunk = CheckInRunner.tally(groups: groups, rescue: rescue, allowsSmartPicks: allowsSmartPicks)
    }

    private func askForNotifications() async {
        guard !demo else { return }
        let center = UNUserNotificationCenter.current()
        let current = await center.notificationSettings()
        if current.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        await refreshPermissionState()
    }

    private func askForCalendar() async -> Bool {
        guard !demo else { return true }
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess { return true }
        guard status == .notDetermined else {
            calendarDenied = true
            return false
        }
        let granted = (try? await EKEventStore().requestFullAccessToEvents()) ?? false
        calendarDenied = !granted
        return granted
    }

    private func refreshPermissionState() async {
        guard !demo else { return }
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationsDenied = status == .denied && settings.wantsNotifications
        let calendar = EKEventStore.authorizationStatus(for: .event)
        calendarDenied = settings.calendarOn && calendar != .fullAccess && calendar != .notDetermined
    }

    /// Recorded check-ins, oldest first, for the report.
    var history: [CheckInReading] { store.history }
    var latest: CheckInReading? { store.latestJunk }
}

extension CheckInCenter: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let isCheckIn = response.notification.request.identifier.hasPrefix("checkin-")
        Task { @MainActor in
            if isCheckIn { CheckInCenter.shared.showReport = true }
            completionHandler()
        }
    }
}

/// The work of one check-in, the same in the foreground and in the background.
enum CheckInRunner {
    static let reminderID = "checkin-reminder"
    static let eventPrefix = "checkin-event-"

    /// Looks at storage, sends any alerts once, records a check-in when one is due, and plans the notifications.
    /// `recount` also remakes the junk totals from the last check, leaving out anything since deleted.
    static func run(recount: Bool) async {
        let store = CheckInStore()
        let pro = store.proSeen
        let settings = store.settings.effective(pro: pro)
        if recount, let fresh = await self.recount(allowsSmartPicks: pro || Grandfather.isSet()), !Task.isCancelled {
            store.latestJunk = fresh
        }
        guard !Task.isCancelled else { return }
        let reading = currentReading(store: store)

        if let reading {
            // Every look at storage adds to the free-space trend shown in the Storage Checkup.
            if reading.totalBytes > 0 { FreeSpaceTrend.record(reading.freeBytes, at: reading.date) }
            let result = CheckInAlerts.evaluate(reading, settings: settings, state: store.alertState)
            store.alertState = result.state
            for alert in result.alerts {
                await post(id: alert.identifier, title: alert.title, body: alert.body, at: nil)
            }
            if CheckInPlan.isDue(now: reading.date, last: store.history.last?.date, settings: settings) {
                store.record(reading)
                var state = store.alertState
                state.libraryBaseline = reading.libraryCount ?? state.libraryBaseline
                store.alertState = state
            }
        }
        await planReminder(settings: settings, store: store)
        await planEvents(settings: settings, reading: reading)
    }

    /// Free space now, with the last check's totals.
    static func currentReading(store: CheckInStore, now: Date = .now) -> CheckInReading? {
        guard let device = DeviceStorage.current() else { return nil }
        let last = store.latestJunk
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let count = (access == .authorized || access == .limited) ? PHAsset.fetchAssets(with: nil).count : nil
        return CheckInReading(date: now, freeBytes: device.available, totalBytes: device.total,
                              junkBytes: last?.junkBytes, libraryCount: count, groups: last?.groups ?? [:],
                              proJunkBytes: last?.proJunkBytes)
    }

    /// Junk totals from Free up's groups: every smart group (each item once) plus duplicate copies.
    /// Smart groups are smart picks: without them (`allowsSmartPicks` false) their space is counted in
    /// `proJunkBytes`, never in `junkBytes`, so "ready to clear" is what this plan can clear.
    /// Every group's own tally is kept either way; the report lists it with the PRO badge.
    static func tally(groups: [CleanupGroup], rescue: RescueSummary, allowsSmartPicks: Bool = true,
                      now: Date = .now) -> CheckInReading {
        var seen = Set<String>()
        var smartBytes: Int64 = 0
        var tallies: [String: CheckInTally] = [:]
        for group in groups where group.id != "for-you" {
            tallies[group.id] = CheckInTally(count: group.items.count, bytes: group.bytes)
            for item in group.items where seen.insert(item.id).inserted { smartBytes += item.displayBytes }
        }
        tallies["duplicates"] = CheckInTally(count: rescue.duplicateCopies, bytes: rescue.duplicateBytes)
        let junk = rescue.duplicateBytes + (allowsSmartPicks ? smartBytes : 0)
        tallies["videos"] = CheckInTally(count: rescue.videos.count, bytes: rescue.videoBytes)
        tallies["screenshots"] = CheckInTally(count: rescue.screenshots.items.count, bytes: rescue.screenshots.localBytes)
        return CheckInReading(date: now, freeBytes: 0, totalBytes: 0, junkBytes: junk, libraryCount: nil, groups: tallies,
                              proJunkBytes: allowsSmartPicks ? 0 : smartBytes)
    }

    /// Remakes the totals from the saved check and recognition results, without anything deleted since.
    /// Reads only; stops as soon as iOS asks.
    static func recount(allowsSmartPicks: Bool) async -> CheckInReading? {
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard access == .authorized || access == .limited,
              let saved = try? InventoryStore.openDefault().load() else { return nil }
        let ids = saved.assets.map(\.id)
        var present = Set<String>()
        PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil).enumerateObjects { asset, _, _ in
            present.insert(asset.localIdentifier)
        }
        guard !Task.isCancelled else { return nil }
        let snapshot = saved.removing(Set(ids).subtracting(present))
        let insights = await InsightStore.standard()?.load() ?? [:]
        guard !Task.isCancelled else { return nil }
        let facts = AssetFacts.all(for: snapshot.assets)
        let groups = CleanupGrouper.groups(in: snapshot, insights: insights, facts: facts)
        guard !Task.isCancelled else { return nil }
        return tally(groups: groups, rescue: RescueSummary(snapshot: snapshot), allowsSmartPicks: allowsSmartPicks)
    }

    /// The repeating reminder, with the latest numbers when there are some.
    private static func planReminder(settings: CheckInSettings, store: CheckInStore) async {
        let center = UNUserNotificationCenter.current()
        guard let parts = CheckInPlan.components(for: settings) else {
            center.removePendingNotificationRequests(withIdentifiers: [reminderID])
            return
        }
        let history = store.history
        let content = UNMutableNotificationContent()
        content.title = CheckInText.title(settings.frequency)
        content.body = CheckInText.body(latest: history.last, previous: history.dropLast().last)
        content.sound = .default
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: true)
        try? await center.add(UNNotificationRequest(identifier: reminderID, content: content, trigger: trigger))
    }

    /// Reminders before and after big events in the next 14 days. Titles stay in notifications on this iPhone.
    private static func planEvents(settings: CheckInSettings, reading: CheckInReading?) async {
        let center = UNUserNotificationCenter.current()
        let old = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(eventPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: old)
        guard settings.calendarOn, EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }
        let now = Date.now
        let events = upcomingEvents(from: now)
        let notes = EventPicker.notes(for: events, settings: settings, now: now,
                                      freeBytes: reading?.freeBytes, junkBytes: reading?.junkBytes)
        for note in notes {
            await post(id: note.id, title: note.title, body: note.body, at: note.date)
        }
    }

    private static func upcomingEvents(from now: Date) -> [CheckInEvent] {
        let store = EKEventStore()
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(EventPicker.horizon), calendars: nil)
        return store.events(matching: predicate).compactMap { event in
            guard let start = event.startDate, let end = event.endDate else { return nil }
            let kind = event.calendar?.type
            return CheckInEvent(id: event.calendarItemIdentifier, title: event.title ?? "Your event", start: start, end: end,
                                allDay: event.isAllDay,
                                subscribed: kind == .birthday || kind == .subscription || (event.calendar?.isSubscribed ?? false))
        }
    }

    private static func post(id: String, title: String, body: String, at date: Date?) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        var trigger: UNNotificationTrigger?
        if let date {
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        }
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}

/// Background check-ins. iOS decides when these run (often overnight while charging) and skips them
/// in Low Power Mode or after the app is swiped away, so the app also catches up every time it opens.
enum CheckInBackground {
    static let refreshID = "com.bienyam.SmartPhotoVault.checkin.refresh"
    static let recountID = "com.bienyam.SmartPhotoVault.checkin.recount"

    /// Must run before launch finishes.
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshID, using: nil) { task in
            handle(task, recount: false)
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: recountID, using: nil) { task in
            handle(task, recount: true)
        }
    }

    static func schedule(settings: CheckInSettings) {
        let wanted = settings.wantsNotifications
        guard wanted else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshID)
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: recountID)
            return
        }
        let refresh = BGAppRefreshTaskRequest(identifier: refreshID)
        refresh.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 3_600)
        try? BGTaskScheduler.shared.submit(refresh)
        let recount = BGProcessingTaskRequest(identifier: recountID)
        recount.requiresExternalPower = true
        recount.requiresNetworkConnectivity = false
        recount.earliestBeginDate = Date(timeIntervalSinceNow: 12 * 3_600)
        try? BGTaskScheduler.shared.submit(recount)
    }

    private static func handle(_ task: BGTask, recount: Bool) {
        let finish = Once()
        let work = Task {
            await CheckInRunner.run(recount: recount)
            let cancelled = Task.isCancelled
            finish.run { task.setTaskCompleted(success: !cancelled) }
        }
        task.expirationHandler = {
            work.cancel()
            finish.run { task.setTaskCompleted(success: false) }
        }
        schedule(settings: CheckInStore().settings.effective(pro: CheckInStore().proSeen))
    }
}

/// Runs a block at most once, from any thread.
private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ block: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { block() }
    }
}
