import SwiftUI
import UIKit

/// More › Check-ins: how often TidyAway looks at storage, what it tells you about, and calendar reminders.
struct CheckInsView: View {
    /// The app's scan, so the report's rows open the usual review lists.
    var model: DashboardModel?
    @ObservedObject private var center = CheckInCenter.shared
    @EnvironmentObject private var pro: ProStore
    @Environment(\.openURL) private var openURL
    @State private var offer: ProOffer?

    /// What the locked rows open: a half sheet, never the whole Pro page at once.
    private static let proOffer = ProOffer(
        id: "checkins", title: "More check-ins",
        what: "adds daily or weekly check-ins, alerts when free space runs low or clutter builds up, and reminders before trips and big events.",
        found: "The monthly reminder stays free.", symbol: "bell.badge")

    private var settings: CheckInSettings { center.settings }
    /// The frequency that actually runs. After Pro lapses a saved daily or weekly choice runs monthly;
    /// the saved choice is kept, so it comes back with Pro.
    private var runningFrequency: CheckInFrequency { settings.effective(pro: pro.allows(.extraCheckIns)).frequency }

    var body: some View {
        List {
            Section {
                Text("A regular look at your storage. Nothing is removed without you.")
                    .font(.subheadline).foregroundStyle(ArchiveStyle.muted)
            }
            Section("How often") {
                frequencyPicker
                if runningFrequency != .off {
                    DatePicker("Time", selection: timeBinding, displayedComponents: .hourAndMinute)
                        .accessibilityIdentifier("checkins-time")
                    if runningFrequency == .weekly {
                        Picker("Day", selection: binding(\.weekday)) {
                            ForEach(1...7, id: \.self) { day in
                                Text(Calendar.current.weekdaySymbols[day - 1]).tag(day)
                            }
                        }
                        .accessibilityIdentifier("checkins-weekday")
                    }
                    if runningFrequency == .monthly {
                        Picker("Day of the month", selection: binding(\.dayOfMonth)) {
                            ForEach(1...28, id: \.self) { day in Text(ordinal(day)).tag(day) }
                        }
                        .accessibilityIdentifier("checkins-day")
                    }
                }
            }

            Section {
                proToggle("Free space drops below", detail: nil, isOn: \.lowSpaceOn, id: "checkins-low")
                if pro.allows(.extraCheckIns) && settings.lowSpaceOn {
                    choice("Alert below", values: CheckInSettings.lowSpaceChoices, value: \.lowSpaceGB) { "\($0) GB" }
                }
                proToggle("Clutter grows by", detail: nil, isOn: \.junkGrowthOn, id: "checkins-junk")
                if pro.allows(.extraCheckIns) && settings.junkGrowthOn {
                    choice("Alert when it grows", values: CheckInSettings.junkChoices, value: \.junkGrowthGB) { "\($0) GB" }
                }
                proToggle("After lots of new photos", detail: "\(settings.newPhotos.formatted()) or more since the last check-in",
                          isOn: \.newPhotosOn, id: "checkins-photos")
                if pro.allows(.extraCheckIns) && settings.newPhotosOn {
                    choice("New photos", values: CheckInSettings.newPhotoChoices, value: \.newPhotos) { "\($0.formatted())" }
                }
            } header: {
                proHeader("Also tell me when")
            }

            Section {
                proToggle("Use my calendar", detail: "Trips, weddings, birthdays, games. Read on this \(Device.name) only.",
                          isOn: \.calendarOn, id: "checkins-calendar",
                          info: "When this is on, TidyAway looks at your calendar for the next 14 days to spot trips, all-day and multi-day events, and events like weddings, birthdays, concerts and games. It reminds you to make room before, and offers to help tidy the new photos after. Event names appear only in notifications on this \(Device.name). Nothing from your calendar is saved, logged or sent anywhere.")
                if pro.allows(.extraCheckIns) && settings.calendarOn {
                    choice("Remind me", values: CheckInSettings.daysBeforeChoices, value: \.daysBefore) {
                        $0 == 1 ? "1 day before" : "\($0) days before"
                    }
                    Toggle("Help me tidy after", isOn: binding(\.tidyAfter))
                        .tint(Brand.safe)
                        .accessibilityIdentifier("checkins-after")
                }
                if center.calendarDenied {
                    permissionNote("Calendar access is off for TidyAway. Turn it on in Settings to get reminders before big events.")
                }
            } header: {
                proHeader("Before big events")
            }

            Section {
                if center.notificationsDenied {
                    permissionNote("Notifications are off for TidyAway, so check-ins can't reach you. Turn them on in Settings.")
                }
                Label("Reminders arrive on time. Numbers refresh when your \(Device.name) allows, usually overnight while charging.",
                      systemImage: "checkmark.shield")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(ArchiveStyle.safeText)
                    .listRowBackground(ArchiveStyle.safeBack)
                    .accessibilityIdentifier("checkins-note")
                NavigationLink { CheckInReportView(model: model) } label: {
                    Label("See the latest check-in", systemImage: "chart.bar.xaxis")
                }
                .accessibilityIdentifier("checkins-report")
            }
        }
        .navigationTitle("Check-ins")
        .navigationBarTitleDisplayMode(.inline)
        .proSheet($offer, pro: pro)
    }

    private var frequencyPicker: some View {
        HStack(spacing: 4) {
            ForEach(CheckInFrequency.allCases) { frequency in
                let chosen = runningFrequency == frequency
                let locked = frequency.needsPro && !pro.allows(.extraCheckIns)
                Button {
                    if locked { offer = Self.proOffer } else { change { $0.frequency = frequency } }
                } label: {
                    HStack(spacing: 3) {
                        Text(frequency.label)
                        if locked { ProBadge() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .foregroundStyle(chosen ? ArchiveStyle.onSelected : ArchiveStyle.ink)
                    .background(chosen ? ArchiveStyle.selected : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("checkins-\(frequency.rawValue)")
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .accessibilityHint(locked ? "TidyAway Pro" : "")
            }
        }
        .padding(3)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func proHeader(_ title: String) -> some View {
        HStack(spacing: 6) {
            Text(title)
            if !pro.allows(.extraCheckIns) { ProBadge() }
        }
    }

    /// A Pro switch. Without Pro it shows the PRO badge and opens the half sheet instead.
    @ViewBuilder
    private func proToggle(_ title: String, detail: String?, isOn: WritableKeyPath<CheckInSettings, Bool>,
                           id: String, info: String? = nil) -> some View {
        if pro.allows(.extraCheckIns) {
            Toggle(isOn: binding(isOn)) { rowLabel(title, detail: detail, info: info) }
                .tint(Brand.safe)
                .accessibilityIdentifier(id)
        } else {
            Button { offer = Self.proOffer } label: {
                HStack {
                    rowLabel(title, detail: detail, info: nil)
                    Spacer()
                    ProBadge()
                }
            }
            .foregroundStyle(ArchiveStyle.ink)
            .accessibilityIdentifier(id)
            .accessibilityHint("TidyAway Pro")
        }
    }

    private func rowLabel(_ title: String, detail: String?, info: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail { Text(detail).font(.caption).foregroundStyle(ArchiveStyle.muted) }
            }
            if let info { InfoButton(title: title, text: info).foregroundStyle(ArchiveStyle.muted) }
        }
    }

    private func choice(_ title: String, values: [Int], value: WritableKeyPath<CheckInSettings, Int>,
                        label: @escaping (Int) -> String) -> some View {
        Picker(title, selection: binding(value)) {
            ForEach(values, id: \.self) { Text(label($0)).tag($0) }
        }
    }

    private func permissionNote(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(Brand.caution)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
            }
            .font(.footnote.weight(.semibold))
        }
    }

    private func ordinal(_ day: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .ordinal
        return formatter.string(from: NSNumber(value: day)) ?? "\(day)"
    }

    private var timeBinding: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: settings.hour, minute: settings.minute, second: 0, of: .now) ?? .now
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            change {
                $0.hour = parts.hour ?? 19
                $0.minute = parts.minute ?? 0
            }
        }
    }

    private func binding<T>(_ path: WritableKeyPath<CheckInSettings, T>) -> Binding<T> {
        Binding {
            center.settings[keyPath: path]
        } set: { value in
            change { $0[keyPath: path] = value }
        }
    }

    private func change(_ edit: @escaping (inout CheckInSettings) -> Void) {
        let unlocked = pro.allows(.extraCheckIns)
        Task { await center.update(edit, pro: unlocked) }
    }
}

/// What a check-in found: junk ready to clear, free space over the last check-ins, and what's new.
/// Every row opens the usual review list, where nothing is selected until you choose.
struct CheckInReportView: View {
    @ObservedObject private var center = CheckInCenter.shared
    @EnvironmentObject private var pro: ProStore
    /// Set when the report has the app's scan to open review lists from.
    var model: DashboardModel?
    var openFreeUp: (() -> Void)?
    @State private var storage = DeviceStorage.current()
    @State private var groups: [CleanupGroup] = []
    @State private var offer: ProOffer?

    private var latest: CheckInReading? { center.latest }
    private var history: [CheckInReading] { Array(center.history.suffix(6)) }
    private var previous: CheckInReading? {
        guard let latest else { return nil }
        return center.history.last { $0.date < latest.date && $0.junkBytes != nil }
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text(Date.now.formatted(.dateTime.month(.wide)) + " check-in")
                        .font(.subheadline).foregroundStyle(ArchiveStyle.muted)
                    if let junk = latest?.junkBytes {
                        Text(junk > 0 ? "\(junk.fileSize) ready to clear" : "Nothing to clear")
                            .font(.title2.bold())
                            .accessibilityIdentifier("report-headline")
                        if !pro.allows(.smartPicks), let extra = latest?.proJunkBytes, extra > 0 {
                            // Smart picks stay out of the headline on a free plan; their rows carry the PRO badge below.
                            Text("+ \(extra.fileSize) more with TidyAway Pro")
                                .font(.footnote).foregroundStyle(ArchiveStyle.muted)
                                .accessibilityIdentifier("report-pro-extra")
                        }
                    } else {
                        Text("Run a check to see your numbers")
                            .font(.title3.bold())
                            .accessibilityIdentifier("report-headline")
                    }
                    if let storage { bar(storage) }
                }
                .padding(.vertical, 4)
            }

            if history.count > 1 {
                Section("Free space, last \(history.count) check-ins") {
                    trend
                }
            }

            if let latest, !latest.groups.isEmpty {
                Section(previous == nil ? "Found in the last check" : "New since last time") {
                    ForEach(rows(latest), id: \.id) { row in
                        destination(for: row)
                    }
                }
            }

            Section {
                if let openFreeUp {
                    Button("Open Free up") { openFreeUp() }
                        .accessibilityIdentifier("report-free-up")
                }
                Text("Nothing is selected for you. You choose, then Apple asks to confirm.")
                    .font(.footnote).foregroundStyle(ArchiveStyle.muted)
            }
        }
        .navigationTitle("Check-in")
        .navigationBarTitleDisplayMode(.inline)
        .proSheet($offer, pro: pro)
        .task { await makeGroups() }
    }

    private struct Row {
        let id: String
        let title: String
        let detail: String
        let bytes: Int64
    }

    private static let names: [String: String] = [
        "look-alike": "Look-alike shots", "blurry": "Blurry photos", "accidental": "Accidental shots", "dark": "Too dark to see",
        "expired": "Receipts & documents", "old-screenshots": "Old screenshots", "screens": "Photos of screens & slides",
        "duplicates": "Duplicates", "videos": "Large videos"
    ]

    private func rows(_ latest: CheckInReading) -> [Row] {
        Self.names.keys.sorted().compactMap { id -> Row? in
            guard let tally = latest.groups[id], tally.count > 0, let name = Self.names[id] else { return nil }
            var detail = "\(tally.count.formatted())"
            if let before = previous?.groups[id] {
                let added = tally.count - before.count
                if added > 0 { detail += " · \(added.formatted()) new" }
            }
            return Row(id: id, title: name, detail: detail, bytes: tally.bytes)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    /// Smart picks follow the same rule as on Free up: without Pro (or 1.0 grandfathering) the row
    /// shows the PRO badge and opens the half sheet, never the list. Duplicates and Large videos stay free.
    @ViewBuilder
    private func destination(for row: Row) -> some View {
        let locked = !ProGate.reportRowOpens(row.id, pro: pro.unlocked, grandfathered: pro.grandfathered)
        let label = HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.title).font(.body.weight(.semibold))
                    if locked { ProBadge() }
                }
                Text(row.detail).font(.caption).foregroundStyle(ArchiveStyle.muted)
            }
            Spacer()
            Text(row.bytes.fileSize).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.primary)
        }
        if locked {
            Button {
                offer = ProOffer(id: "report-\(row.id)", title: row.title, what: ProGate.smartPickWhat(row.id),
                                 found: "Found on this \(Device.name): \(row.detail), about \(row.bytes.fileSize). You still approve every one.",
                                 symbol: "sparkles")
            } label: { label }
            .foregroundStyle(ArchiveStyle.ink)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Available in TidyAway Pro")
            .accessibilityIdentifier("report-\(row.id)")
        } else if let model, let list = list(for: row.id, model: model) {
            NavigationLink { list } label: { label }
                .accessibilityIdentifier("report-\(row.id)")
        } else {
            label.accessibilityIdentifier("report-\(row.id)")
        }
    }

    private func list(for id: String, model: DashboardModel) -> AnyView? {
        // Never hand out a smart-pick list without the gate, whoever calls this.
        guard ProGate.reportRowOpens(id, pro: pro.unlocked, grandfathered: pro.grandfathered) else { return nil }
        if id == "duplicates" { return AnyView(DuplicatesListView(model: model)) }
        if id == "videos", let rescue = model.rescue {
            return AnyView(CleanupListView(title: "Large videos",
                                           guidance: "Videos are usually the biggest files on an \(Device.name). These are the ones on this \(Device.name), largest first.",
                                           items: rescue.videos, source: "Large videos", allowsRemoval: true, model: model))
        }
        guard let group = groups.first(where: { $0.id == id }) else { return nil }
        return AnyView(CleanupListView(title: group.title, guidance: group.info, items: group.items, source: group.title,
                                       allowsRemoval: true, model: model, sets: group.sets))
    }

    private func bar(_ storage: DeviceStorage) -> some View {
        let junk = min(latest?.junkBytes ?? 0, storage.used)
        let total = Double(max(storage.total, 1))
        return VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    Rectangle().fill(ArchiveStyle.muted.opacity(0.7))
                        .frame(width: geometry.size.width * Double(storage.used - junk) / total)
                    Rectangle().fill(Brand.primary)
                        .frame(width: geometry.size.width * Double(junk) / total)
                    Spacer(minLength: 0)
                }
                .background(Brand.surface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .frame(height: 12)
            .accessibilityHidden(true)
            Text("\(storage.available.fileSize) free of \(storage.total.fileSize)")
                .font(.caption).foregroundStyle(ArchiveStyle.muted)
        }
    }

    private var trend: some View {
        let highest = Double(max(history.map(\.freeBytes).max() ?? 1, 1))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(Array(history.enumerated()), id: \.offset) { index, reading in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(index == history.count - 1 ? Brand.primary : Brand.surface)
                        .frame(height: max(6, 60 * Double(reading.freeBytes) / highest))
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 60, alignment: .bottom)
            if let first = history.first, let last = history.last {
                Text("\(first.freeBytes.fileSize) free on \(first.date.formatted(date: .abbreviated, time: .omitted)) · \(last.freeBytes.fileSize) now")
                    .font(.caption).foregroundStyle(ArchiveStyle.muted)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("report-trend")
    }

    /// The same groups Free up shows, so each row opens the list it counts.
    private func makeGroups() async {
        guard let model, !model.isDemo, let snapshot = model.rescue?.snapshot else { return }
        let found = InsightModel.shared.insights
        groups = await Task.detached(priority: .utility) {
            CleanupGrouper.groups(in: snapshot, insights: found, facts: AssetFacts.all(for: snapshot.assets))
        }.value
    }
}
