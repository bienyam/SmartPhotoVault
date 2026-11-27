import Foundation
import UserNotifications

/// One local reminder two days before a TidyAway Pro free trial ends. It is planned only when a
/// purchase starts a free trial, and that is the only moment notification permission is asked for.
/// It is cleared when the trial is cancelled, converts to a paid plan, or ends. Apple's own
/// transaction and renewal info give the end date; nothing is sent anywhere.
enum TrialReminder {
    static let id = "pro-trial-ending"
    /// How long before the trial's end the reminder arrives.
    static let lead: TimeInterval = 2 * 24 * 3_600
    /// Set while a reminder is pending, so a check with no trial only clears one this app planned.
    static let scheduledKey = "pro.trialReminderScheduled"

    /// A free trial in progress: when it ends, and whether it will turn into a paid plan.
    struct Trial: Equatable {
        var ends: Date
        var willRenew: Bool
    }

    enum Decision: Equatable {
        case schedule(at: Date)
        case none
    }

    /// When to remind, if at all. Nothing when there is no trial, it has been cancelled (it won't
    /// renew, so there is nothing to warn about), it has ended, or its two-day mark has passed.
    static func decision(for trial: Trial?, now: Date) -> Decision {
        guard let trial, trial.willRenew, trial.ends > now else { return .none }
        let at = trial.ends.addingTimeInterval(-lead)
        return at > now ? .schedule(at: at) : .none
    }

    static let title = "Your free trial ends in 2 days"

    static func body(ends: Date) -> String {
        "Your TidyAway Pro free trial ends on \(day(ends)). Nothing to do if you want to keep it; cancel in Settings › your name › Subscriptions."
    }

    /// Shown in the Pro section instead when no reminder could be set (notifications are off, or
    /// the trial ends within two days).
    static func dateLine(ends: Date) -> String {
        "Your free trial ends on \(day(ends)). Nothing to do if you want to keep Pro; to stop it, cancel in Settings › your name › Subscriptions."
    }

    static func day(_ date: Date) -> String { date.formatted(date: .long, time: .omitted) }

    static func allowed(_ status: UNAuthorizationStatus) -> Bool {
        status == .authorized || status == .provisional || status == .ephemeral
    }

    /// Plans or clears the reminder. Returns true when a reminder is pending afterwards.
    /// Asks for notification permission only when `mayAsk` (a purchase that just started the trial).
    @MainActor
    static func sync(_ trial: Trial?, mayAsk: Bool, now: Date = .now, defaults: UserDefaults = .standard) async -> Bool {
        let center = UNUserNotificationCenter.current()
        guard let trial, case .schedule(let at) = decision(for: trial, now: now) else {
            if defaults.bool(forKey: scheduledKey) {
                center.removePendingNotificationRequests(withIdentifiers: [id])
                defaults.set(false, forKey: scheduledKey)
            }
            return false
        }
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined, mayAsk {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            status = await center.notificationSettings().authorizationStatus
        }
        guard allowed(status) else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body(ends: trial.ends)
        content.sound = .default
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: at)
        let request = UNNotificationRequest(identifier: id, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
        do {
            try await center.add(request)
        } catch {
            return false
        }
        defaults.set(true, forKey: scheduledKey)
        return true
    }
}
