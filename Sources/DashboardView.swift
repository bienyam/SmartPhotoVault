import SwiftUI
import Photos

/// The launch tab: the Dial with one button to find space, then the finds as picture cards.
struct FreeUpView: View {
    @ObservedObject var model: DashboardModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var storage = DeviceStorage.current()
    @State private var showRecentlyDeleted = false
    @ObservedObject private var insights = InsightModel.shared
    @State private var section = FreeUpSection.forYou
    /// Smart groups from on-device recognition, remade as results come in.
    @State private var smart: [CleanupGroup] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.isScanning {
                        scanning
                    } else if let rescue = model.rescue {
                        resultDial(rescue)
                    } else {
                        start
                    }
                    problems
                    if let rescue = model.rescue {
                        finds(rescue)
                        RecentlyDeletedCard { showRecentlyDeleted = true }
                        footer(rescue)
                    } else {
                        RecentlyDeletedCard { showRecentlyDeleted = true }
                    }
                }
                .frame(maxWidth: 520)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .background(Brand.background)
            .safeAreaInset(edge: .bottom) {
                if !model.isScanning, let rescue = model.rescue,
                   rescue.duplicateCopies > 0 || !rescue.videos.isEmpty || !rescue.screenshots.items.isEmpty {
                    nextStep(rescue)
                }
            }
            .navigationTitle("TidyAway")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $showRecentlyDeleted, onDismiss: { storage = DeviceStorage.current() }) {
                RecentlyDeletedGuide()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { storage = DeviceStorage.current() }
            }
            .task(id: "\(insights.revision)-\(model.rescue?.snapshot.assets.count ?? 0)-\(model.isScanning)") { await remakeSmart() }
        }
    }

    // MARK: - Dial

    private var usedSummary: String {
        storage.map { "\($0.used.fileSize) of \($0.total.fileSize) used" } ?? "Storage on this \(Device.name)"
    }

    private var start: some View {
        VStack(spacing: 16) {
            Text("Storage full? Get your camera back.")
                .font(.title.bold())
                .foregroundStyle(ArchiveStyle.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            StorageDial(parts: [DialPart(fraction: storage?.usedFraction ?? 0, color: DialPart.photos)], summary: usedSummary) {
                DialButton { model.startDuplicateScan() }
            }
            if let storage {
                (Text("\(storage.available.fileSize) free").font(.title3.bold()).foregroundColor(ArchiveStyle.ink)
                    + Text(" of \(storage.total.fileSize)").font(.body).foregroundColor(ArchiveStyle.muted))
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 2) {
                Text("Nothing is removed until you approve it.")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(ArchiveStyle.safeText)
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(ArchiveStyle.safeBack, in: Capsule())
                InfoButton(title: "How it works",
                           text: "TidyAway looks through the photos and videos on this \(Device.name) and lists the biggest things you could remove. It reads them on your \(Device.name) and sends nothing anywhere. You choose what goes, sign off, and Apple asks you to confirm.")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var scanning: some View {
        VStack(spacing: 14) {
            Text("Looking through your photos").font(.title2.bold()).foregroundStyle(ArchiveStyle.ink)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            StorageDial(parts: [DialPart(fraction: model.total > 0 ? Double(model.completed) / Double(model.total) : 0, color: DialPart.photos)],
                        summary: "\(model.completed.formatted()) of \(model.total.formatted()) checked") {
                VStack(spacing: 4) {
                    if let rescue = model.rescue {
                        heroNumber(rescue.upToBytes.fileSize)
                        Text("found so far").font(.subheadline).foregroundStyle(ArchiveStyle.muted)
                    } else {
                        ProgressView().controlSize(.large)
                    }
                }
            }
            if model.total > 0 {
                Text("Looking through \(model.completed.formatted()) of \(model.total.formatted())")
                    .font(.subheadline).monospacedDigit().foregroundStyle(ArchiveStyle.muted)
            }
            Text("The biggest finds show up first. You can start clearing them now.")
                .font(.footnote).foregroundStyle(ArchiveStyle.muted)
                .multilineTextAlignment(.center)
            Button("Stop", role: .cancel) { model.cancel() }
                .buttonStyle(ArchiveOutlineStyle())
        }
        .frame(maxWidth: .infinity)
    }

    private func heroNumber(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 46, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .foregroundStyle(ArchiveStyle.selected)
            .contentTransition(.numericText())
    }

    private func parts(_ rescue: RescueSummary) -> [DialPart] {
        guard let storage, storage.total > 0 else { return [] }
        let photos = model.isDemo ? 0 : min(rescue.libraryLocalBytes, storage.used)
        return [DialPart(fraction: Double(photos) / Double(storage.total), color: DialPart.photos),
                DialPart(fraction: Double(max(0, storage.used - photos)) / Double(storage.total), color: DialPart.other)]
    }

    @ViewBuilder
    private func resultDial(_ rescue: RescueSummary) -> some View {
        VStack(spacing: 12) {
            // App Store pictures are made from sample data and leave this label off.
            if model.isDemo, !LaunchFlags.has("--store-pictures") {
                Label("Sample photos, not your library", systemImage: "testtube.2")
                    .font(.subheadline.weight(.semibold))
            }
            Text("You could free up to").font(.headline).foregroundStyle(ArchiveStyle.muted)
                .accessibilityAddTraits(.isHeader)
            StorageDial(parts: parts(rescue), summary: usedSummary) {
                VStack(spacing: 2) {
                    heroNumber(rescue.upToBytes.fileSize).accessibilityIdentifier("hero-bytes")
                    Text(rescue.iCloudBytes > 0 ? "on this \(Device.name), plus \(rescue.iCloudBytes.fileSize) in iCloud" : "on this \(Device.name)")
                        .font(.subheadline).foregroundStyle(ArchiveStyle.muted)
                        .multilineTextAlignment(.center)
                }
            }
            if let storage {
                let photos = model.isDemo ? 0 : min(rescue.libraryLocalBytes, storage.used)
                let rest = max(0, storage.used - photos)
                VStack(spacing: 4) {
                    legend(DialPart.photos, "Photos & videos", model.isDemo ? "—" : photos.fileSize)
                    legend(DialPart.other, "Apps, System Data & other", model.isDemo ? "—" : rest.fileSize)
                    legend(Color.gray.opacity(0.35), "Free", storage.available.fileSize)
                }
                NavigationLink {
                    WhatsUsingView(storage: storage, photosBytes: rescue.libraryLocalBytes, isDemo: model.isDemo)
                } label: {
                    HStack(spacing: 4) {
                        Text(!model.isDemo && storage.used > 0 && Double(photos) / Double(storage.used) < 0.4
                             ? "Most of your space isn't photos. See what's using it" : "See what's using it")
                            .multilineTextAlignment(.leading)
                        Image(systemName: "chevron.right").font(.footnote.bold())
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(ArchiveStyle.link)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("whats-using")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func legend(_ color: Color, _ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(title)
            Spacer()
            Text(value).foregroundStyle(ArchiveStyle.muted)
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Finds

    @ViewBuilder
    private var problems: some View {
        if let error = model.errorMessage {
            Text(error).font(.subheadline).foregroundStyle(Brand.caution)
        }
        if model.authorization == .denied || model.authorization == .restricted {
            VStack(alignment: .leading, spacing: 8) {
                Text("TidyAway needs access to your photos to find space.")
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private func finds(_ rescue: RescueSummary) -> some View {
        sectionPills
        switch section {
        case .forYou:
            if let pick = CleanupGrouper.suggestion(from: smart) { suggestion(pick) }
            smartSections
            heading("By type")
            typeCards(rescue)
        case .smart:
            smartSections
            if smart.isEmpty && !insights.running {
                Text("No smart groups yet. They appear as TidyAway looks through your photos.")
                    .font(.subheadline).foregroundStyle(ArchiveStyle.muted)
            }
        case .byType:
            typeCards(rescue)
        }
    }

    private var sectionPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(FreeUpSection.allCases, id: \.self) { value in
                    let on = section == value
                    Button(value.rawValue) { section = value }
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .foregroundStyle(on ? ArchiveStyle.onSelected : ArchiveStyle.ink)
                        .background(on ? ArchiveStyle.selected : Color.clear, in: Capsule())
                        .overlay(Capsule().stroke(on ? Color.clear : ArchiveStyle.border, lineWidth: 1.5))
                        .contentShape(Capsule())
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(on ? .isSelected : [])
                        .accessibilityIdentifier("freeup-\(value)")
                }
            }
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.title3.weight(.heavy)).foregroundStyle(ArchiveStyle.ink)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }

    /// One suggestion that combines the safest smart groups, so the first decision is one tap.
    private func suggestion(_ pick: CleanupGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Suggested for you", systemImage: "sparkles")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(Color(red: 1, green: 0.541, blue: 0.361))
                Spacer()
                CardInfo(title: "Suggested for you", text: pick.info)
            }
            Text(pick.title).font(.title2.bold())
            Text(pick.why).font(.footnote).foregroundStyle(.white.opacity(0.78))
            NavigationLink { smartList(pick) } label: {
                Text("Review \(pick.items.count.formatted()) \(pick.items.count == 1 ? "item" : "items")")
                    .font(.headline)
                    .foregroundStyle(Color(red: 0.078, green: 0.086, blue: 0.122))
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .background(Color(red: 1, green: 0.541, blue: 0.361), in: RoundedRectangle(cornerRadius: 14))
            }
            .accessibilityIdentifier("smart-for-you")
        }
        .foregroundStyle(.white)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Color(red: 0.17, green: 0.18, blue: 0.27), Color(red: 0.078, green: 0.086, blue: 0.122)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 22))
    }

    @ViewBuilder
    private var smartSections: some View {
        ForEach([CleanupGroup.Tier.safe, .probably], id: \.self) { tier in
            let list = smart.filter { $0.tier == tier }
            if !list.isEmpty {
                Text(tier.rawValue.uppercased())
                    .font(.caption.weight(.heavy)).tracking(0.7)
                    .foregroundStyle(ArchiveStyle.muted)
                    .padding(.top, 4)
                LazyVGrid(columns: typeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                    ForEach(list) { smartCard($0) }
                }
            }
        }
        if insights.running {
            Label("Smart groups grow as TidyAway looks through your photos: \(insights.done.formatted()) of \(insights.total.formatted()). On this \(Device.name) only.",
                  systemImage: "sparkles")
                .font(.footnote).foregroundStyle(ArchiveStyle.muted)
        }
    }

    private func smartCard(_ group: CleanupGroup) -> some View {
        ZStack(alignment: .topTrailing) {
            NavigationLink { smartList(group) } label: {
                ArchiveCard(title: group.title,
                            detail: "\(group.items.count.formatted()) · \(group.bytes.fileSize)",
                            coverID: group.coverID, why: group.why, symbol: group.symbol)
            }
            .find("smart-\(group.id)")
            CardInfo(title: group.title, text: group.info)
        }
    }

    private func smartList(_ group: CleanupGroup) -> some View {
        CleanupListView(title: group.id == "for-you" ? "Suggested for you" : group.title, guidance: group.info,
                        items: group.items, source: group.id == "for-you" ? "Suggested for you" : group.title,
                        allowsRemoval: true, model: model, sets: group.sets)
    }

    /// Remakes the smart groups from the scan and the recognition results, off the main thread.
    private func remakeSmart() async {
        guard !model.isScanning, !model.isDemo, let snapshot = model.rescue?.snapshot else { return }
        insights.start(snapshot.assets)
        let found = insights.insights
        let made = await Task.detached(priority: .utility) {
            let facts = AssetFacts.all(for: snapshot.assets)
            return CleanupGrouper.groups(in: snapshot, insights: found, facts: facts)
        }.value
        smart = made
    }

    /// Today's finds by type, each with what it holds.
    @ViewBuilder
    private func typeCards(_ rescue: RescueSummary) -> some View {
        FindTag(kind: .safe)
        ZStack(alignment: .topTrailing) {
            NavigationLink { duplicatesList } label: {
                ArchiveCard(title: "Duplicates",
                            detail: rescue.duplicateCopies == 0 ? "None" : "\(rescue.duplicateCopies.formatted()) extra \(rescue.duplicateCopies == 1 ? "copy" : "copies") · \(rescue.duplicateBytes.fileSize)",
                            coverID: rescue.duplicateGroups.first?.assets.first?.id)
            }
            .find("row-duplicates")
            CardInfo(title: "Duplicates", text: "Exact copies, byte for byte. In each set one copy stays, shown first with a lock; it can't be selected and Select all never includes it. Favorites are kept. Nothing is selected until you choose.")
        }
        FindTag(kind: .look)
        // Not a lazy grid: every find exists from the start, also for VoiceOver.
        let pair = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        pair {
            ZStack(alignment: .topTrailing) {
                NavigationLink { videosList(rescue) } label: {
                    ArchiveCard(title: "Large videos",
                                detail: rescue.videos.isEmpty ? "None" : split(rescue.videoBytes, rescue.videoICloudBytes),
                                coverID: rescue.videos.first?.id)
                }
                .find("row-videos")
                CardInfo(title: "Large videos", text: "The videos on this \(Device.name), largest first. Every video in the list can be selected; nothing is selected until you choose. Favorites are kept.")
            }
            ZStack(alignment: .topTrailing) {
                NavigationLink { screenshotsList(rescue) } label: {
                    ArchiveCard(title: "Screenshots",
                                detail: rescue.screenshots.items.isEmpty ? "None" : split(rescue.screenshots.localBytes, rescue.screenshots.iCloudBytes),
                                coverID: rescue.screenshots.items.first?.id)
                }
                .find("row-screenshots")
                CardInfo(title: "Screenshots", text: CleanCategory.screenshots.guidance)
            }
        }
        FindTag(kind: .decide)
        ZStack(alignment: .topTrailing) {
            NavigationLink { MoreTypesView(types: rescue.otherTypes, model: model) } label: {
                ArchiveCard(title: "More types", detail: rescue.otherBytes.fileSize,
                            coverID: rescue.otherTypes.first { !$0.items.isEmpty }?.items.first?.id)
            }
            .find("row-more")
            CardInfo(title: "More types", text: "GIFs, bursts, Live Photos, slo-mo and other kinds of items, each in its own list. Nothing is selected until you choose.")
        }
    }

    private var duplicatesList: some View { DuplicatesListView(model: model) }

    private func videosList(_ rescue: RescueSummary) -> some View {
        CleanupListView(title: "Large videos",
                        guidance: "Videos are usually the biggest files on an \(Device.name). These are the ones on this \(Device.name), largest first.",
                        items: rescue.videos, source: "Large videos", allowsRemoval: true, model: model)
    }

    private func screenshotsList(_ rescue: RescueSummary) -> some View {
        CleanupListView(title: "Screenshots", guidance: CleanCategory.screenshots.guidance,
                        items: rescue.screenshots.items, source: "Screenshots", allowsRemoval: true, model: model)
    }

    /// One clear next step: the safest find first, then the biggest.
    @ViewBuilder
    private func nextStep(_ rescue: RescueSummary) -> some View {
        Group {
            if rescue.duplicateCopies > 0 {
                NavigationLink("Review duplicates · \(rescue.duplicateBytes.fileSize)") { duplicatesList }
            } else if !rescue.videos.isEmpty {
                NavigationLink("Review large videos · \(split(rescue.videoBytes, rescue.videoICloudBytes))") { videosList(rescue) }
            } else if !rescue.screenshots.items.isEmpty {
                NavigationLink("Review screenshots · \(split(rescue.screenshots.localBytes, rescue.screenshots.iCloudBytes))") { screenshotsList(rescue) }
            }
        }
        .buttonStyle(ArchiveButtonStyle())
        .accessibilityIdentifier("review-next")
        .frame(maxWidth: 520)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(.regularMaterial)
    }

    @ViewBuilder
    private func footer(_ rescue: RescueSummary) -> some View {
        if rescue.includesICloud {
            HStack(alignment: .top, spacing: 4) {
                Text("Some items are kept in iCloud, with a small copy on this \(Device.name).")
                    .font(.footnote).foregroundStyle(ArchiveStyle.muted)
                InfoButton(title: "Items in iCloud",
                           text: "Optimize \(Device.name) Storage is on, so the full-size originals of these items are in iCloud and your \(Device.name) keeps smaller copies. Deleting them frees their full size in iCloud and the smaller copy on this \(Device.name). Duplicates can only be confirmed for items whose originals are on this \(Device.name).")
            }
            .accessibilityIdentifier("icloud-note")
        }
        if model.libraryChanged {
            Text("Your photos changed since this check.").font(.footnote).foregroundStyle(ArchiveStyle.muted)
        }
        if let status = model.duplicateScanStatus, status != "Scan complete." {
            Text(status).font(.footnote).foregroundStyle(ArchiveStyle.muted)
        }
        if !model.isScanning {
            HStack {
                NavigationLink { ScanDetailsView(snapshot: rescue.snapshot, isDemo: model.isDemo) } label: {
                    Label("Scan details", systemImage: "list.bullet.rectangle")
                }
                .accessibilityIdentifier("scan-details")
                Spacer()
                Button(model.isDemo ? "Check my photos instead" : "Check again") { model.startDuplicateScan() }
                    .accessibilityIdentifier("check-again")
            }
            .font(.subheadline.weight(.bold))
            .foregroundStyle(ArchiveStyle.link)
            .frame(minHeight: 44)
        }
    }

    /// "1.2 GB", "In iCloud · 4 GB" or "1.2 GB + 4 GB in iCloud": phone space first, never mixed.
    private func split(_ local: Int64, _ iCloud: Int64) -> String {
        if iCloud == 0 { return local.fileSize }
        if local == 0 { return "In iCloud · \(iCloud.fileSize)" }
        return "\(local.fileSize) + \(iCloud.fileSize) in iCloud"
    }
}

private extension View {
    /// A find card: one button to VoiceOver, named by its title and size.
    func find(_ identifier: String) -> some View {
        buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(identifier)
    }
}

/// What's using this iPhone. iOS doesn't let apps read the Settings breakdown (apps, System Data),
/// so this shows what TidyAway can measure: photos and videos on the phone, free space, and the rest.
struct PhoneBreakdown: View {
    let storage: DeviceStorage
    let photosBytes: Int64
    let isDemo: Bool

    private var photos: Int64 { isDemo ? 0 : min(photosBytes, storage.used) }
    private var rest: Int64 { max(0, storage.used - photos) }
    private var mostlyNotPhotos: Bool { !isDemo && storage.used > 0 && Double(photos) / Double(storage.used) < 0.4 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What's using your \(Device.name)").font(.headline)
            GeometryReader { proxy in
                HStack(spacing: 2) {
                    Rectangle().fill(Brand.primary)
                        .frame(width: proxy.size.width * fraction(photos))
                    Rectangle().fill(Color.gray.opacity(0.7))
                        .frame(width: proxy.size.width * fraction(rest))
                    Rectangle().fill(Color.secondary.opacity(0.2))
                }
                .clipShape(Capsule())
            }
            .frame(height: 12)
            legend(Brand.primary, "Photos & videos", isDemo ? "—" : photos.fileSize)
            legend(Color.gray.opacity(0.7), "Apps, System Data & other", isDemo ? "—" : rest.fileSize)
            legend(Color.secondary.opacity(0.2), "Free", storage.available.fileSize)
            if mostlyNotPhotos {
                NavigationLink { StorageExplainer() } label: {
                    HStack {
                        Text("Most of your space isn't photos. See how to trim apps and System Data")
                            .font(.subheadline.weight(.semibold)).multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right").font(.footnote.bold())
                    }
                    .foregroundStyle(Brand.primary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("breakdown-explainer")
            }
            HStack(spacing: 4) {
                Text("Per-app sizes are in Settings, General, \(Device.name) Storage.").font(.caption).foregroundStyle(.secondary)
                InfoButton(title: "Why not per app?",
                           text: "Apple keeps the per-app and System Data figures inside Settings, and doesn't let any app read them. TidyAway measures your photos and videos itself and works out the rest from your \(Device.name)'s used space.")
            }
        }
        .padding(16)
        .background(Brand.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("phone-breakdown")
    }

    private func fraction(_ bytes: Int64) -> CGFloat {
        storage.total > 0 ? CGFloat(Double(bytes) / Double(storage.total)) : 0
    }

    private func legend(_ color: Color, _ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(title).font(.subheadline)
            Spacer()
            Text(value).font(.subheadline).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// GIFs, Live Photos, slo-mo and the rest, each opening its own list.
struct MoreTypesView: View {
    let types: [CleanCategorySummary]
    @ObservedObject var model: DashboardModel

    var body: some View {
        List {
            if types.isEmpty {
                Text("Check your photos again to sort them by type.")
            }
            ForEach(types, id: \.category) { summary in
                NavigationLink {
                    CleanupListView(title: summary.category.title, guidance: summary.category.guidance,
                                    items: summary.items, source: summary.category.title,
                                    allowsRemoval: summary.category.allowsRemoval, model: model)
                } label: {
                    HStack {
                        Label(summary.category.title, systemImage: summary.category.systemImage)
                        Spacer()
                        Text(detail(summary)).foregroundStyle(.secondary)
                    }
                }
                .disabled(summary.items.isEmpty)
                .accessibilityIdentifier("category-\(summary.category.rawValue)")
            }
        }
        .navigationTitle("More types")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detail(_ summary: CleanCategorySummary) -> String {
        guard !summary.items.isEmpty else { return "None" }
        if summary.category == .bursts { return "\(summary.items.count.formatted()) · view only" }
        return "\(summary.items.count.formatted()) · \(summary.localBytes > 0 ? summary.localBytes.fileSize : "in iCloud")"
    }
}

/// Everything that isn't cleanup or archiving, one row each.
struct MoreView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { LedgerView(model: model) } label: {
                        Label("Activity", systemImage: "checkmark.shield")
                    }
                    .accessibilityIdentifier("more-activity")
                    NavigationLink { ProUpgradeView() } label: {
                        Label("TidyAway Pro", systemImage: "sparkles")
                    }
                    .accessibilityIdentifier("more-pro")
                }
                Section("Tips") {
                    NavigationLink { MessagesAttachmentsGuide() } label: {
                        Label("Photos and videos in Messages", systemImage: "message")
                    }
                    .accessibilityIdentifier("guide-messages")
                    NavigationLink { StorageExplainer() } label: {
                        Label("Where your storage goes", systemImage: "internaldrive")
                    }
                    .accessibilityIdentifier("more-explainer")
                    NavigationLink { CloudDownloadRemovalView() } label: {
                        Label("Free iCloud Drive downloads", systemImage: "icloud.and.arrow.down")
                    }
                    .accessibilityIdentifier("more-icloud-downloads")
                    NavigationLink { OptimizeStorageTip() } label: {
                        Label("Keep smaller copies with iCloud", systemImage: "iphone")
                    }
                    .accessibilityIdentifier("more-optimize")
                }
                Section {
                    NavigationLink { HelpPrivacyView(model: model) } label: {
                        Label("Help & privacy", systemImage: "questionmark.circle")
                    }
                    .accessibilityIdentifier("more-help")
                }
            }
            .navigationTitle("More")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Storage TidyAway can't clear itself, explained plainly with the steps to clear it yourself.
struct StorageExplainer: View {
    var body: some View {
        List {
            Section("Apps: usually the biggest win") {
                Text("1. Open Settings, then General, then \(Device.name) Storage. Apps are listed largest first.")
                Text("2. Tap a big app you rarely use and choose Offload App. It frees the app but keeps its documents and data; tap its icon later to reinstall.")
                Text("3. To do this automatically, turn on Offload Unused Apps on that same screen (or in Settings, App Store).")
                Text("Delete App removes its data too, so only use it for apps you don't need anymore.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("System Data") {
                Text("Caches, logs and temporary files that iOS manages. It grows and shrinks on its own; apps can't clear it.")
                Text("Restarting your \(Device.name) often shrinks it. If it stays very large, updating iOS usually helps.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Recently Deleted") {
                Text("Photos you delete wait here for 30 days and still use space. Open Photos, tap Collections, scroll to Utilities, tap Recently Deleted, then Select, the ••• button and Delete All.")
            }
            Section("Files downloaded from iCloud Drive") {
                Text("Files you open from iCloud Drive stay downloaded. In the Files app, touch and hold a file or folder, then tap Remove Download. It stays in iCloud.")
            }
            Section("Apps") {
                Text("In Settings, General, \(Device.name) Storage, choose an app and tap Offload App. Its documents stay, and it reinstalls when you tap it.")
            }
        }
        .navigationTitle("Where your storage goes")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Apple doesn't let apps switch on Optimize Storage, so this is the one setting to change yourself.
struct OptimizeStorageTip: View {
    var body: some View {
        List {
            Section {
                Text("If you use iCloud Photos, your \(Device.name) can keep smaller versions of photos and videos and leave the full-size originals in iCloud. It frees space without deleting anything.")
            }
            Section("Turn it on") {
                Text("1. Open Settings and tap your name.")
                Text("2. Tap iCloud, then Photos.")
                Text("3. Choose Optimize \(Device.name) Storage.")
            }
            Section {
                Text("You need enough iCloud storage to hold your whole library. Menu names can differ slightly between iOS versions.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Keep smaller copies")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct HelpPrivacyView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        List {
            Section("How TidyAway works") {
                Text("Free up finds the biggest things on this \(Device.name). You pick what goes, sign off, and Apple asks you to confirm. Deleted items wait in Recently Deleted for 30 days; empty it in Photos to get the space back.")
                Text("Archive copies photos and files to a place you choose and checks every copy. It only adds copies there; it never deletes or changes anything in your archive.")
            }
            Section("Privacy") {
                Text("TidyAway reads the Apple Photos items you authorize. Scanning and exact duplicate matching run on your device.")
                Text("The app stores the latest completed check and its activity log locally. The check can include Photos identifiers, file names, dates, favorite status, resource sizes and hashes, the names of your albums, and an approximate location rounded to about 1 km. The app does not transmit this information to the developer or include advertising or analytics.")
                Text("When you choose a place on the Archive tab, the map is loaded from Apple Maps. Your photo locations stay on your \(Device.name).")
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
        }
        .navigationTitle("Help & privacy")
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum FreeUpSection: String, CaseIterable { case forYou = "For you", smart = "Smart picks", byType = "By type" }

/// The info button on a picture card: what the group holds, what is selected and what is kept.
struct CardInfo: View {
    let title: String
    let text: String

    var body: some View {
        InfoButton(title: title, text: text)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.4), radius: 3)
    }
}
