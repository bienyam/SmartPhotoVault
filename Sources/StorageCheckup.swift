import SwiftUI

/// One guided step of the Storage Checkup. The person does it in Settings or another app;
/// TidyAway only says where to go and measures free space afterwards.
struct CheckupStep: Identifiable, Equatable {
    let id: String
    let title: String
    /// One line under the title while the step is closed.
    let subtitle: String
    /// Where to go, in Apple's own words. Text only: TidyAway never opens Settings pages.
    let path: String
    let actions: [String]
    let caution: String
}

enum Checkup {
    /// Since iOS 18 an app's settings sit under Settings › Apps.
    static var appsPath: String {
        if #available(iOS 18, *) { return "Settings › Apps" }
        return "Settings"
    }

    private static var safariFirst: String {
        appsPath == "Settings" ? "Open **Settings** and tap **Safari**." : "Open **Settings**, tap **Apps**, then **Safari**."
    }

    static let steps: [CheckupStep] = [
        CheckupStep(
            id: "update", title: "Install the waiting iOS update", subtitle: "Settings › General › Software Update",
            path: "Settings › General › Software Update",
            actions: ["Open **Settings** and tap **General**.",
                      "Tap **Software Update**.",
                      "If an update has downloaded, tap **Install Now** or **Update Tonight**."],
            caution: "A downloaded update can hold several GB until it is installed. If nothing is waiting, skip this step."),
        CheckupStep(
            id: "whatsapp", title: "WhatsApp: Manage storage", subtitle: "Done in WhatsApp",
            path: "WhatsApp › Settings › Storage and Data › Manage Storage",
            actions: ["Open **WhatsApp** and tap **Settings**.",
                      "Tap **Storage and Data**, then **Manage Storage**.",
                      "Open a large chat, select what to remove, then tap the Trash."],
            caution: "WhatsApp deletes these for good. TidyAway can't see or undo this. If you don't use WhatsApp, skip this step."),
        CheckupStep(
            id: "recently-deleted", title: "Empty Recently Deleted", subtitle: "Done in Photos",
            path: "Photos › Collections › Utilities › Recently Deleted",
            actions: ["Open **Photos** and tap **Collections**. (On iOS 17, tap **Albums**.)",
                      "Swipe up to **Utilities** and tap **Recently Deleted**.",
                      "Look through it. Then tap **Select**, the **•••** button and **Delete All**."],
            caution: "This can't be undone. With iCloud Photos it empties on all your devices. Look through it first."),
        CheckupStep(
            id: "messages", title: "Review big attachments in Messages", subtitle: "One-time review",
            path: "Settings › General › \(Device.name) Storage › Messages",
            actions: ["Open **Settings** and search “\(Device.name) Storage”.",
                      "Tap **Messages**, then **Videos** or **Photos**.",
                      "Tap **Edit**, pick what to remove, then tap the Trash."],
            caution: "Deleted attachments are gone for good. TidyAway can't see or undo this."),
        CheckupStep(
            id: "offload", title: "Offload apps you rarely open", subtitle: "Keeps their documents and data",
            path: "Settings › General › \(Device.name) Storage",
            actions: ["Open **Settings**, tap **General**, then **\(Device.name) Storage**.",
                      "Apps are listed largest first. Tap one you rarely open.",
                      "Tap **Offload App**. Its icon stays; tap it later to get the app back."],
            caution: "Offload App keeps the app's documents and data. Delete App removes them too."),
        CheckupStep(
            id: "downloads", title: "Clear podcast and music downloads", subtitle: "In Podcasts and Music",
            path: "Podcasts › Library › Downloaded",
            actions: ["Open **Podcasts**, tap **Library**, then **Downloaded**.",
                      "Tap the **•••** button and choose **Remove All Downloads**.",
                      "For music, open **\(appsPath) › Music** and turn on **Optimize Storage**."],
            caution: "Shows and songs stay in your library and can be downloaded again."),
        CheckupStep(
            id: "safari", title: "Clear Safari website data", subtitle: "\(appsPath) › Safari",
            path: "\(appsPath) › Safari › Clear History and Website Data",
            actions: [safariFirst,
                      "Tap **Clear History and Website Data**.",
                      "Choose a time range and confirm."],
            caution: "This signs you out of websites and clears your browsing history.")
    ]
}

/// Where a Checkup stands. Kept between launches, because iOS may close TidyAway while Settings is open.
struct CheckupProgress: Codable, Equatable {
    static let key = "checkup.progress"
    /// A Checkup left alone this long starts again from the current free space.
    static let staleAfter: TimeInterval = 24 * 3_600

    var startedAt: Date
    /// Free space when the Checkup began.
    var startFree: Int64
    /// Free space at the last measurement: what the next step is compared with.
    var lastFree: Int64
    /// Step id to how much free space rose after it. Zero means no change was seen.
    var results: [String: Int64] = [:]
    var skipped: [String] = []

    init(free: Int64, now: Date = .now) {
        startedAt = now
        startFree = free
        lastFree = free
    }

    func isDone(_ step: CheckupStep) -> Bool { results[step.id] != nil }
    func isSkipped(_ step: CheckupStep) -> Bool { skipped.contains(step.id) }

    var doneCount: Int { Checkup.steps.filter(isDone).count }

    /// The first step that is neither done nor skipped.
    var next: CheckupStep? { Checkup.steps.first { !isDone($0) && !isSkipped($0) } }

    /// How much free space rose since the Checkup began. Nil when it didn't.
    func gained(now free: Int64) -> Int64? { SpaceGained.bytes(before: startFree, after: free) }

    /// Marks a step done with what the iPhone measured before and after it.
    /// Small changes are just iOS at work, so they count as no change.
    mutating func measured(_ step: CheckupStep, free: Int64) {
        results[step.id] = SpaceGained.bytes(before: lastFree, after: free) ?? 0
        skipped.removeAll { $0 == step.id }
        lastFree = free
    }

    mutating func skip(_ step: CheckupStep) {
        guard !isDone(step), !skipped.contains(step.id) else { return }
        skipped.append(step.id)
    }

    /// "Free space rose 3.1 GB" or the honest alternative. Never "TidyAway freed".
    static func resultLine(_ gained: Int64) -> String {
        gained > 0 ? "Free space rose \(gained.fileSize)" : "No change yet"
    }

    static func load(store: UserDefaults = .standard, now: Date = .now) -> CheckupProgress? {
        guard let data = store.data(forKey: key),
              let saved = try? JSONDecoder().decode(CheckupProgress.self, from: data),
              now.timeIntervalSince(saved.startedAt) < staleAfter else { return nil }
        return saved
    }

    func save(store: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { store.set(data, forKey: Self.key) }
    }
}

/// A small line of free space over time.
struct Sparkline: View {
    let points: [FreeSpacePoint]

    var body: some View {
        let heights = FreeSpaceTrend.heights(points)
        GeometryReader { proxy in
            let step = heights.count > 1 ? proxy.size.width / CGFloat(heights.count - 1) : 0
            let spots = heights.enumerated().map { index, height in
                CGPoint(x: CGFloat(index) * step, y: proxy.size.height * (1 - CGFloat(height)))
            }
            ZStack {
                Path { path in
                    guard let first = spots.first else { return }
                    path.move(to: first)
                    for spot in spots.dropFirst() { path.addLine(to: spot) }
                }
                .stroke(Brand.safe, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                if let last = spots.last {
                    Circle().fill(Brand.safe).frame(width: 8, height: 8).position(last)
                }
            }
        }
        .frame(height: 44)
        .padding(.vertical, 4)
        .accessibilityHidden(true)
    }
}

/// Free space over time with one line of words under it. Shown once there are two readings.
struct FreeSpaceTrendCard: View {
    let points: [FreeSpacePoint]

    var body: some View {
        if points.count > 1, let last = points.last {
            VStack(alignment: .leading, spacing: 6) {
                Text("FREE SPACE OVER TIME")
                    .font(.caption.weight(.heavy)).tracking(0.7)
                    .foregroundStyle(Brand.muted)
                    .accessibilityAddTraits(.isHeader)
                Sparkline(points: points)
                Text("\(last.freeBytes.fileSize) free now. \(FreeSpaceTrend.summary(points) ?? "")")
                    .font(.footnote).foregroundStyle(Brand.muted)
                Text("Noted at each check-in and each time you measure here. TidyAway can't tell which app changed.")
                    .font(.caption).foregroundStyle(Brand.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .homeCard()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("checkup-trend")
        }
    }
}

/// Storage Checkup: guided steps for the space that isn't photos. After each one, TidyAway reads
/// free space again and says how much it rose. It never opens Settings and never claims the saving.
struct StorageCheckupView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var progress = CheckupProgress(free: 0)
    @State private var free: Int64 = 0
    @State private var open: String?
    @State private var trend: [FreeSpacePoint] = []
    @State private var showRecentlyDeleted = false
    @State private var ready = false

    private var steps: [CheckupStep] { Checkup.steps }

    var body: some View {
        ZStack {
            HomeBackdrop()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summary
                    let finished = steps.filter { progress.isDone($0) && $0.id != open }
                    if !finished.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(finished.enumerated()), id: \.element.id) { index, step in
                                if index > 0 { line }
                                doneRow(step)
                            }
                        }
                        .homeCard(padding: 0)
                    }
                    if let step = steps.first(where: { $0.id == open }) { openCard(step) }
                    let waiting = steps.filter { !progress.isDone($0) && $0.id != open }
                    if !waiting.isEmpty {
                        VStack(spacing: 0) {
                            ForEach(Array(waiting.enumerated()), id: \.element.id) { index, step in
                                if index > 0 { line }
                                waitingRow(step)
                            }
                        }
                        .homeCard(padding: 0)
                    }
                    if progress.next == nil && open == nil {
                        Text("That's every step. Come back any time; the Checkup starts fresh after a day.")
                            .font(.subheadline).foregroundStyle(Brand.muted)
                            .accessibilityIdentifier("checkup-finished")
                    }
                    FreeSpaceTrendCard(points: trend)
                    Text("System Data is space \(Device.name) manages itself. No app can clear it.")
                        .font(.footnote).foregroundStyle(Brand.muted)
                    if !progress.results.isEmpty || !progress.skipped.isEmpty {
                        Button("Start the Checkup again") { restart() }
                            .font(.subheadline.weight(.bold))
                            .tint(ArchiveStyle.link)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("checkup-restart")
                    }
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Storage Checkup")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        // A guided flow: the tab bar steps aside until it is done.
        .toolbar(.hidden, for: .tabBar)
        .sheet(isPresented: $showRecentlyDeleted, onDismiss: refresh) { RecentlyDeletedGuide() }
        .onAppear(perform: begin)
        .onChange(of: scenePhase) { _, phase in
            // Coming back from Settings shows the new free space; the step is marked only by the button.
            if phase == .active { refresh() }
        }
    }

    private var line: some View {
        Rectangle().fill(Brand.hairline).frame(height: 1).padding(.horizontal, 16)
    }

    // MARK: Summary

    private var summary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("FREE SPACE · MEASURED BY \(Device.name.uppercased())")
                    .font(.caption.weight(.heavy)).tracking(0.7)
                    .foregroundStyle(Brand.muted)
                Spacer(minLength: 8)
                Text("\(progress.doneCount) of \(steps.count) done")
                    .font(.footnote).foregroundStyle(Brand.muted)
                    .accessibilityIdentifier("checkup-count")
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) { figures }
                VStack(alignment: .leading, spacing: 2) { figures }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Free space was \(progress.startFree.fileSize) when you started and is \(free.fileSize) now.")
            sinceStart
            ProgressView(value: Double(progress.doneCount), total: Double(max(steps.count, 1)))
                .tint(Brand.safe)
                .accessibilityLabel("Steps done")
        }
        .homeCard()
    }

    @ViewBuilder
    private var figures: some View {
        Text(progress.startFree.fileSize).font(.title3).foregroundStyle(Brand.muted)
        Image(systemName: "arrow.right").font(.subheadline).foregroundStyle(Brand.muted)
        Text(free.fileSize).font(.system(.largeTitle, design: .rounded).weight(.heavy)).foregroundStyle(Brand.ink)
            .contentTransition(.numericText())
    }

    @ViewBuilder
    private var sinceStart: some View {
        if let gained = progress.gained(now: free) {
            (Text("Free space rose \(gained.fileSize)").fontWeight(.bold).foregroundColor(ArchiveStyle.safeText)
                + Text(" since you started. You did the steps; TidyAway only measured.").foregroundColor(Brand.muted))
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("checkup-gained")
        } else {
            Text("Do a step, come back, and tap “I've done this”. TidyAway measures free space before and after.")
                .font(.subheadline).foregroundStyle(Brand.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Rows

    private func doneRow(_ step: CheckupStep) -> some View {
        let gained = progress.results[step.id] ?? 0
        return Button { open = step.id } label: {
            HStack(spacing: 12) {
                Image(systemName: "checkmark")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(ArchiveStyle.safeText)
                    .frame(width: 30, height: 30)
                    .background(Brand.safeTile, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.ink)
                        .multilineTextAlignment(.leading)
                    Text(gained > 0 ? step.subtitle : "No change yet. Items may be waiting in Recently Deleted.")
                        .font(.footnote).foregroundStyle(Brand.muted)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                if gained > 0 {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("Free space rose").font(.caption).foregroundStyle(ArchiveStyle.safeText)
                        Text(gained.fileSize).font(.headline).foregroundStyle(ArchiveStyle.safeText)
                    }
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(step.title). Done. \(CheckupProgress.resultLine(gained)).")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("checkup-done-\(step.id)")
    }

    private func waitingRow(_ step: CheckupStep) -> some View {
        let number = (steps.firstIndex(of: step) ?? 0) + 1
        return Button { open = step.id } label: {
            HStack(spacing: 12) {
                Text("\(number)")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Brand.muted)
                    .frame(width: 30, height: 30)
                    .background(Brand.surface, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.ink)
                        .multilineTextAlignment(.leading)
                    Text(progress.isSkipped(step) ? "Skipped. Tap to do it now." : step.subtitle)
                        .font(.footnote).foregroundStyle(Brand.muted)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Brand.muted)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(number) of \(steps.count). \(step.title). \(progress.isSkipped(step) ? "Skipped" : step.subtitle).")
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("checkup-step-\(step.id)")
    }

    private func openCard(_ step: CheckupStep) -> some View {
        let number = (steps.firstIndex(of: step) ?? 0) + 1
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Text("\(number)")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(ArchiveStyle.onAction)
                    .frame(width: 34, height: 34)
                    .background(ArchiveStyle.action, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(step.title).font(.headline).foregroundStyle(Brand.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    Text("Step \(number) of \(steps.count)").font(.footnote).foregroundStyle(Brand.muted)
                }
            }
            Text(step.path)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Brand.ink)
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("Where to go: \(step.path)")
                .accessibilityIdentifier("checkup-path")
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(step.actions.enumerated()), id: \.offset) { index, action in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(Brand.muted)
                        Text(LocalizedStringKey(action)).foregroundStyle(Brand.ink)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.body)
                    .accessibilityElement(children: .combine)
                }
            }
            Text(step.caution)
                .font(.subheadline)
                .foregroundStyle(Brand.chipText)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.chipBack, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityIdentifier("checkup-caution")
            if step.id == "recently-deleted" {
                Button("See the steps with pictures") { showRecentlyDeleted = true }
                    .font(.subheadline.weight(.bold))
                    .tint(ArchiveStyle.link)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("checkup-recently-deleted")
            }
            if let gained = progress.results[step.id] {
                Label(gained > 0 ? "\(CheckupProgress.resultLine(gained))." : "No change yet. Items may be waiting in Recently Deleted.",
                      systemImage: gained > 0 ? "checkmark.circle.fill" : "clock")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(gained > 0 ? ArchiveStyle.safeText : Brand.caution)
                    .accessibilityIdentifier("checkup-result")
            }
            HStack(spacing: 12) {
                Button(progress.isDone(step) ? "Measure again" : "I've done this · measure") { measure(step) }
                    .buttonStyle(ArchiveButtonStyle())
                    .accessibilityIdentifier("checkup-measure")
                Button(progress.isDone(step) ? "Close" : "Skip") { skip(step) }
                    .font(.body)
                    .tint(Brand.muted)
                    .frame(minWidth: 60, minHeight: 44)
                    .accessibilityIdentifier("checkup-skip")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(ArchiveStyle.action, lineWidth: 1.5))
    }

    // MARK: Actions

    private func begin() {
        guard !ready else { return }
        ready = true
        // UI tests start each Checkup from the beginning.
        if LaunchFlags.has("--reset-checkup") { UserDefaults.standard.removeObject(forKey: CheckupProgress.key) }
        free = DeviceStorage.current()?.available ?? 0
        if let sample = DemoLibrary.checkup(free: free) {
            // App Store pictures: one step done and free space risen. Not saved.
            progress = sample
        } else {
            progress = CheckupProgress.load() ?? CheckupProgress(free: free)
            progress.save()
        }
        open = progress.next?.id
        FreeSpaceTrend.record(free)
        trend = FreeSpaceTrend.points()
    }

    private func refresh() {
        guard let now = DeviceStorage.current()?.available else { return }
        free = now
    }

    private func measure(_ step: CheckupStep) {
        refresh()
        Haptics.light()
        progress.measured(step, free: free)
        progress.save()
        FreeSpaceTrend.record(free)
        trend = FreeSpaceTrend.points()
        // A step that changed nothing stays open with its note; otherwise move on.
        if (progress.results[step.id] ?? 0) > 0 { open = progress.next?.id }
    }

    private func skip(_ step: CheckupStep) {
        progress.skip(step)
        progress.save()
        open = progress.next?.id
    }

    private func restart() {
        refresh()
        progress = CheckupProgress(free: free)
        progress.save()
        open = progress.next?.id
    }
}
