import SwiftUI
import StoreKit

/// Where TidyAway sends people for help and for a rating.
enum SupportLinks {
    /// The support page listed on the App Store.
    static let support = URL(string: "https://github.com/bienyam/SmartPhotoVault/issues")!
    /// Opens the App Store's own "Write a Review" page for TidyAway.
    static let review = URL(string: "https://apps.apple.com/app/id6836546403?action=write-review")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }
}

/// One of the guides under More › Tips.
enum Tip: String, CaseIterable, Identifiable {
    case messages, storage, optimize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .messages: "Photos and videos in Messages"
        case .storage: "Where your storage goes"
        case .optimize: "Keep smaller copies with iCloud"
        }
    }

    var icon: String {
        switch self {
        case .messages: "message"
        case .storage: "internaldrive"
        case .optimize: "iphone"
        }
    }

    /// The identifiers these rows have always had.
    var identifier: String {
        switch self {
        case .messages: "guide-messages"
        case .storage: "more-explainer"
        case .optimize: "more-optimize"
        }
    }

    /// The tip shown on the More tab changes each week and comes round again.
    static func ofTheWeek(_ date: Date = .now, calendar: Calendar = .current) -> Tip {
        let week = calendar.component(.weekOfYear, from: date)
        return allCases[week % allCases.count]
    }
}

/// Everything that isn't cleanup or archiving: the plan first, then staying on top of storage,
/// tips, the look, and help.
struct MoreView: View {
    @ObservedObject var model: DashboardModel
    @EnvironmentObject private var pro: ProStore
    @ObservedObject private var checkIns = CheckInCenter.shared
    @ObservedObject private var google = GoogleDriveAccount.shared
    @ObservedObject private var oneDrive = CloudAccount.oneDrive
    @ObservedObject private var dropbox = CloudAccount.dropbox
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(AppearanceStore.key) private var appearance = AppearanceChoice.system.rawValue
    @State private var storage = DeviceStorage.current()
    @State private var hasDrive = SavedDrive.load() != nil

    private var look: AppearanceChoice { AppearanceChoice(rawValue: appearance) ?? .system }

    private var placeCount: Int {
        (hasDrive ? 1 : 0) + (google.connected ? 1 : 0) + (oneDrive.connected ? 1 : 0) + (dropbox.connected ? 1 : 0)
    }

    private var lastActivity: String? {
        model.activity.first?.date.formatted(.dateTime.month(.abbreviated).day())
    }

    var body: some View {
        NavigationStack {
            ZStack {
                HomeBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        planCard
                        heading("Stay on top")
                        card {
                            NavigationLink { CheckInsView(model: model) } label: {
                                MoreRowLabel(title: "Check-ins", icon: "bell",
                                             value: checkIns.settings.effective(pro: pro.unlocked).frequency.label)
                            }
                            .moreRow("more-checkins")
                            line
                            NavigationLink { StorageInsightsView(model: model) } label: {
                                MoreRowLabel(title: "Storage insights", icon: "chart.pie",
                                             value: storage.map { "\($0.available.fileSize) free" })
                            }
                            .moreRow("more-insights")
                            line
                            NavigationLink { LedgerView(model: model) } label: {
                                MoreRowLabel(title: "Activity", icon: "checkmark.shield", value: lastActivity, safe: true)
                            }
                            .moreRow("more-activity")
                            line
                            NavigationLink { ArchivePlacesView() } label: {
                                MoreRowLabel(title: "Archive places", icon: "externaldrive",
                                             value: placeCount > 0 ? "\(placeCount)" : nil)
                            }
                            .moreRow("more-places")
                        }
                        heading("Learn")
                        card {
                            NavigationLink { TipsView() } label: {
                                MoreRowLabel(title: "Tips", icon: "lightbulb",
                                             subtitle: "This week: \(Tip.ofTheWeek().title)")
                            }
                            .moreRow("more-tips")
                        }
                        heading("Display")
                        card {
                            NavigationLink { AppearanceView() } label: {
                                MoreRowLabel(title: "Appearance", icon: "circle.lefthalf.filled", value: look.title)
                            }
                            .moreRow("more-appearance")
                        }
                        heading("Help")
                        card {
                            NavigationLink { HelpFAQView() } label: {
                                MoreRowLabel(title: "Help & FAQ", icon: "questionmark.circle")
                            }
                            .moreRow("more-help")
                            line
                            NavigationLink { PrivacyView() } label: {
                                MoreRowLabel(title: "Privacy", icon: "lock")
                            }
                            .moreRow("more-privacy")
                            line
                            NavigationLink { ContactView() } label: {
                                MoreRowLabel(title: "Contact us", icon: "envelope")
                            }
                            .moreRow("more-contact")
                            line
                            Button { openURL(SupportLinks.review) } label: {
                                MoreRowLabel(title: "Rate TidyAway", icon: "star")
                            }
                            .moreRow("more-rate")
                            .accessibilityHint("Opens the App Store")
                        }
                        Text("TidyAway \(SupportLinks.version)")
                            .font(.footnote)
                            .foregroundStyle(Brand.muted)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 10)
                            .accessibilityIdentifier("more-version")
                    }
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .onAppear {
                storage = DeviceStorage.current()
                hasDrive = SavedDrive.load() != nil
                model.reloadActivity()
            }
        }
    }

    // MARK: Plan card

    private var planCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(pro.looksUnlocked ? "YOUR PLAN · PRO" : "YOUR PLAN · FREE")
                .font(.caption.weight(.heavy)).tracking(0.9)
                .foregroundStyle(Brand.navyAccent)
                .accessibilityLabel(pro.looksUnlocked ? "Your plan: Pro" : "Your plan: Free")
            Text("TidyAway Pro").font(.title2.weight(.heavy)).foregroundStyle(Brand.onNavy)
                .accessibilityAddTraits(.isHeader)
            Text(pro.looksUnlocked ? "Thank you. Everything is unlocked."
                 : "Monthly, or once for life. Your choice.")
                .font(.subheadline).foregroundStyle(Brand.onNavy.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                : AnyLayout(HStackLayout(spacing: 18))
            layout {
                NavigationLink { ProUpgradeView() } label: {
                    Text(pro.looksUnlocked ? "See your plan" : "See Pro")
                        .font(.headline)
                        .foregroundStyle(ArchiveStyle.onAction)
                        .padding(.horizontal, 20)
                        .frame(minHeight: 46)
                        .background(ArchiveStyle.action, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(PressableStyle())
                .accessibilityIdentifier("more-pro")
                Button {
                    Haptics.light()
                    Task { await pro.restore() }
                } label: {
                    HStack(spacing: 8) {
                        Text("Restore Purchases").font(.headline).foregroundStyle(Brand.onNavy)
                        if pro.busy { ProgressView().tint(Brand.onNavy) }
                    }
                    .frame(minHeight: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableStyle())
                .disabled(pro.busy)
                .accessibilityIdentifier("more-restore")
            }
            .padding(.top, 8)
            if pro.connecting {
                Text("Connecting to the App Store…")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Brand.onNavy.opacity(0.82))
            }
            if let notice = pro.notice {
                Text(notice).font(.footnote).foregroundStyle(Brand.onNavy.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("more-restore-notice")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.navy, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Brand.navyEdge, lineWidth: 1))
    }

    // MARK: Pieces

    private func heading(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption.weight(.heavy)).tracking(0.9)
            .foregroundStyle(Brand.muted)
            .padding(.top, 10)
            .padding(.leading, 12)
            .accessibilityLabel(text)
            .accessibilityAddTraits(.isHeader)
    }

    private var line: some View {
        Rectangle().fill(Brand.hairline).frame(height: 1).padding(.horizontal, 16)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .frame(maxWidth: .infinity)
            .background(Brand.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Brand.cardEdge, lineWidth: 1))
    }
}

/// A row on the More tab: icon tile, name, an optional second line, and its current state on the right.
struct MoreRowLabel: View {
    let title: String
    let icon: String
    var value: String? = nil
    var subtitle: String? = nil
    var safe = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(safe ? ArchiveStyle.safeText : Brand.primary)
                .frame(width: 34, height: 34)
                .background(safe ? Brand.safeTile : Brand.moveTile, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(Brand.ink)
                    .multilineTextAlignment(.leading)
                if let subtitle {
                    Text(subtitle).font(.footnote).foregroundStyle(Brand.muted)
                        .multilineTextAlignment(.leading)
                }
                if typeSize.isAccessibilitySize, let value {
                    Text(value).font(.footnote).foregroundStyle(Brand.muted)
                }
            }
            Spacer(minLength: 8)
            if !typeSize.isAccessibilitySize, let value {
                Text(value).font(.subheadline).foregroundStyle(Brand.muted).lineLimit(1)
            }
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Brand.muted)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 54)
        .contentShape(Rectangle())
    }
}

private extension View {
    func moreRow(_ identifier: String) -> some View {
        buttonStyle(PressableStyle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(identifier)
    }
}

// MARK: - Tips

/// Every tip, as before, behind one row. The guides come first; the iCloud Drive tool has its own
/// heading because it does something rather than explains something.
struct TipsView: View {
    var body: some View {
        List {
            Section("Guides") {
                ForEach(Tip.allCases) { tip in
                    NavigationLink { destination(tip) } label: {
                        Label(tip.title, systemImage: tip.icon)
                    }
                    .accessibilityIdentifier(tip.identifier)
                }
            }
            Section("Do it here") {
                NavigationLink { CloudDownloadRemovalView() } label: {
                    Label("Free iCloud Drive downloads", systemImage: "icloud.and.arrow.down")
                }
                .accessibilityIdentifier("more-icloud-downloads")
            }
        }
        .navigationTitle("Tips")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func destination(_ tip: Tip) -> some View {
        switch tip {
        case .messages: MessagesAttachmentsGuide()
        case .storage: StorageExplainer()
        case .optimize: OptimizeStorageTip()
        }
    }
}

// MARK: - Appearance

/// Same as iPhone, Light or Dark. One tick, changes straight away.
struct AppearanceView: View {
    @AppStorage(AppearanceStore.key) private var appearance = AppearanceChoice.system.rawValue

    var body: some View {
        List {
            Section {
                ForEach(AppearanceChoice.allCases) { choice in
                    let on = appearance == choice.rawValue
                    Button {
                        appearance = choice.rawValue
                    } label: {
                        HStack(spacing: 14) {
                            AppearanceSwatch(choice: choice)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(choice.title).font(.body).foregroundStyle(Brand.ink)
                                Text(choice.detail).font(.footnote).foregroundStyle(Brand.muted)
                            }
                            Spacer()
                            if on {
                                Image(systemName: "checkmark").font(.body.weight(.bold)).foregroundStyle(Brand.primary)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier("appearance-\(choice.rawValue)")
                }
            } header: {
                Text("Look")
            } footer: {
                Text("Changes straight away and only affects TidyAway. Your photos and previews are never tinted.")
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A small tile that shows the look itself: cream, navy, or half of each for "Same as iPhone".
struct AppearanceSwatch: View {
    let choice: AppearanceChoice

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        Group {
            switch choice {
            case .system:
                HStack(spacing: 0) { Brand.swatchLight; Brand.swatchDark }
            case .light:
                Brand.swatchLight
            case .dark:
                Brand.swatchDark
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(shape)
        .overlay(shape.stroke(Brand.swatchEdge, lineWidth: 1))
        .accessibilityHidden(true)
    }
}

// MARK: - Storage insights

/// What's using this iPhone, how free space has moved, and the way into the Storage Checkup.
struct StorageInsightsView: View {
    @ObservedObject var model: DashboardModel
    @State private var storage = DeviceStorage.current()
    @State private var trend: [FreeSpacePoint] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let storage {
                    PhoneBreakdown(storage: storage, photosBytes: model.rescue?.libraryLocalBytes ?? 0,
                                   isDemo: model.isDemo || model.rescue == nil)
                    if model.rescue == nil {
                        Text("Check your photos on the Free up tab to see how much of this is photos and videos.")
                            .font(.footnote).foregroundStyle(Brand.muted)
                    }
                }
                FreeSpaceTrendCard(points: trend)
                if trend.count < 2 {
                    Text("A line of your free space over time appears here after a second reading: at a check-in, or each time you measure in the Storage Checkup.")
                        .font(.footnote).foregroundStyle(Brand.muted)
                        .accessibilityIdentifier("insights-trend-note")
                }
                NavigationLink { StorageCheckupView() } label: {
                    Label("Storage Checkup", systemImage: "checklist")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(ArchiveOutlineStyle())
                .accessibilityIdentifier("insights-checkup")
                NavigationLink { CheckInReportView(model: model) } label: {
                    Label("See the latest check-in", systemImage: "chart.bar.xaxis")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(ArchiveStyle.link)
                        .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("insights-report")
            }
            .frame(maxWidth: 520)
            .padding(20)
            .frame(maxWidth: .infinity)
        }
        .background(Brand.background)
        .navigationTitle("Storage insights")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            storage = DeviceStorage.current()
            FreeSpaceTrend.recordNow()
            trend = FreeSpaceTrend.points()
        }
    }
}

// MARK: - Archive places

/// The drives and cloud services TidyAway copies to, in one list. Places are still chosen on the
/// Archive tab when copying; here they can be seen, connected and disconnected.
struct ArchivePlacesView: View {
    @ObservedObject private var google = GoogleDriveAccount.shared
    @ObservedObject private var oneDrive = CloudAccount.oneDrive
    @ObservedObject private var dropbox = CloudAccount.dropbox
    @State private var drive = SavedDrive.load()
    @State private var plugged = false

    var body: some View {
        List {
            Section {
                Text("TidyAway only adds copies to these places. It never deletes or changes anything there.")
                    .font(.subheadline).foregroundStyle(ArchiveStyle.muted)
            }
            Section("Drive") {
                if let drive {
                    LabeledContent(drive.name, value: plugged ? "Plugged in" : "Not plugged in")
                    Button("Forget this drive") {
                        SavedDrive.forget()
                        self.drive = nil
                    }
                    .accessibilityIdentifier("places-forget-drive")
                    Text("Forgetting a drive changes nothing on the drive.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("No drive remembered. Pick one on the Archive tab when you copy.")
                        .foregroundStyle(.secondary)
                }
            }
            Section("Google Drive") {
                if google.connected {
                    LabeledContent("Connected", value: google.email ?? "Google Drive")
                    Button("Disconnect Google Drive") { Task { await google.disconnect() } }
                        .disabled(google.busy)
                } else {
                    Button("Connect Google Drive") { Task { await google.connect() } }
                        .disabled(google.busy)
                        .accessibilityIdentifier("places-google-connect")
                }
                if let message = google.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                }
            }
            ForEach(CloudService.allCases.filter(\.available), id: \.self) { service in
                cloud(service, account: service == .oneDrive ? oneDrive : dropbox)
            }
            Section {
                Text("iCloud Drive, a home file server and other Files locations are chosen on the Archive tab each time you copy.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Archive places")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            drive = SavedDrive.load()
            guard let drive else { return }
            plugged = await Task.detached(priority: .utility) { DriveStatus.read(drive) != nil }.value
        }
    }

    private func cloud(_ service: CloudService, account: CloudAccount) -> some View {
        Section(service.name) {
            if account.connected {
                LabeledContent("Connected", value: account.name ?? service.name)
                Button("Disconnect \(service.name)") { Task { await account.disconnect() } }
                    .disabled(account.busy)
            } else {
                Button("Connect \(service.name)") { Task { await account.connect() } }
                    .disabled(account.busy)
                    .accessibilityIdentifier("places-cloud-connect-\(service.rawValue)")
            }
            if let message = account.message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Help, privacy, contact

/// The help half of what used to be "Help & privacy". Every word is unchanged.
struct HelpFAQView: View {
    var body: some View {
        List {
            Section("How TidyAway works") {
                Text("Free up finds the biggest things on this \(Device.name). You pick what goes, sign off, and Apple asks you to confirm. Deleted items wait in Recently Deleted for 30 days; empty it in Photos to get the space back.")
                Text("Archive copies photos and files to a place you choose and checks every copy. It only adds copies there; it never deletes or changes anything in your archive.")
            }
            Section("Common questions") {
                question("Why didn't my free space change after deleting?",
                         "Deleted photos and videos wait in Recently Deleted for up to 30 days and still use space. Empty that album in Photos to get the space back.")
                question("Can TidyAway delete my favorites?",
                         "No. Favorites are never offered for deletion and can't be selected.")
                question("What is the Storage Score?",
                         "One number from free space alone: free space ÷ total space × 4, capped at 100. It is not a measure of speed, battery or the health of your \(Device.name).")
                question("Can TidyAway clear apps or System Data?",
                         "No app can. The Storage Checkup shows the steps to do it yourself in Settings, then measures your free space again.")
            }
        }
        .navigationTitle("Help & FAQ")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func question(_ title: String, _ answer: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.body.weight(.semibold))
            Text(answer).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The privacy half of what used to be "Help & privacy". Every paragraph is here, unchanged.
struct PrivacyView: View {
    var body: some View {
        List {
            Section("Privacy") {
                Text("TidyAway reads the Apple Photos items you authorize. Scanning and exact duplicate matching run on your device.")
                Text("The app stores the latest completed check and its activity log locally. The check can include Photos identifiers, file names, dates, favorite status, resource sizes and hashes, the names of your albums, and an approximate location rounded to about 1 km. The app does not transmit this information to the developer or include advertising or analytics.")
                Text("When you choose a place on the Archive tab, the map is loaded from Apple Maps. Your photo locations stay on your \(Device.name).")
                Text("Check-ins, if you turn them on, read free space and the last check's totals and keep a short history on this \(Device.name). Reminders before big events read your calendar on this \(Device.name) only; event names appear only in the notifications and are never saved or sent.")
                Text("If you connect Google Drive, Google signs you in and gives TidyAway access only to the files it creates in a TidyAway Archive folder. The sign-in is kept in this \(Device.name)'s Keychain. Disconnecting removes it and revokes access; your archived copies stay in Drive.")
                if CloudService.allCases.contains(where: \.available) {
                    Text("If you connect OneDrive, Microsoft signs you in and gives TidyAway access to your files; TidyAway only adds copies to a TidyAway folder in My files and never opens, changes or deletes anything else. If you connect Dropbox, it gives TidyAway access only to its own folder, Apps › TidyAway. The sign-in is kept in this \(Device.name)'s Keychain. Disconnecting removes it; your archived copies stay there.")
                }
                Text("Checks read originals already available on your \(Device.name). If you approve an archive or restore, the app writes a copy to your chosen folder, downloading the original from iCloud first when it isn't on your \(Device.name). The source stays in place and the provider may sync the copy.")
                Text("After a verified archive copy, the app keeps a local list of the file name, folder, size, checksum and date, with a reference to the folder you chose, so you can find and restore it.")
                Text("If you approve deleting items, the app asks Apple Photos to delete exactly those items. Apple shows its own confirmation and normally keeps deleted items in Recently Deleted for up to 30 days. The approval, item count and outcome are recorded in the local activity log.")
                Text("You can change Photos access in Settings. To remove the local data and activity log from this device, delete the app.")
                Text("Apple handles in-app purchases.")
            }
            Section("New in 1.0.1") {
                Text("The Storage Checkup and Storage insights keep a short history of free space (sizes and dates only) on this \(Device.name). Your choice of Light or Dark is kept on this \(Device.name) too.")
            }
        }
        .navigationTitle("Privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// How to reach support, with the details support will ask for.
struct ContactView: View {
    @Environment(\.openURL) private var openURL

    private var details: String {
        "TidyAway \(SupportLinks.version) (\(SupportLinks.build)), \(Device.name), iOS \(UIDevice.current.systemVersion)"
    }

    var body: some View {
        List {
            Section {
                Text("Tell us what happened and what you expected. Please don't include photos or file names you want to keep private.")
            }
            Section("Include these details") {
                Text(details).textSelection(.enabled)
                    .accessibilityIdentifier("contact-details")
                Button("Copy details") { UIPasteboard.general.string = details }
                    .accessibilityIdentifier("contact-copy")
            }
            Section {
                Button("Open the support page") { openURL(SupportLinks.support) }
                    .accessibilityIdentifier("contact-open")
                    .accessibilityHint("Opens in your browser")
            } footer: {
                Text("The support page opens in your browser. TidyAway sends nothing by itself.")
            }
        }
        .navigationTitle("Contact us")
        .navigationBarTitleDisplayMode(.inline)
    }
}
