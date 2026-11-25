import SwiftUI
import Photos

/// The launch tab: the storage card with the Storage Score, then everything found, on three shelves
/// by how safe it is to clear. The total and the main button stay docked above the tab bar.
struct FreeUpView: View {
    @ObservedObject var model: DashboardModel
    /// The gear in the header opens the More tab, where the settings live.
    var openMore: () -> Void = {}
    @EnvironmentObject private var pro: ProStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var storage = DeviceStorage.current()
    @State private var showRecentlyDeleted = false
    @State private var showScoreInfo = false
    @ObservedObject private var insights = InsightModel.shared
    @ObservedObject private var sorter = ScreenshotSorter.shared
    @State private var section = FreeUpSection.forYou
    /// Smart groups from on-device recognition, remade as results come in.
    @State private var smart: [CleanupGroup] = []
    /// Smart Pro: photos already archived, and look-alike sets for Best shots.
    @State private var archived: [ArchivedPlace] = []
    @State private var sets: [KeepSet] = []
    @State private var totals: TidyTotals?
    @State private var offer: ProOffer?
    @AppStorage("grandfather.noteSeen") private var earlyNoteSeen = false

    var body: some View {
        NavigationStack {
            ZStack {
                // Stays put: only the cards move, passing under the frosted header.
                HomeBackdrop()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        // App Store pictures are made from sample data and leave this label off.
                        if model.isDemo, !LaunchFlags.has("--store-pictures") {
                            Label("Sample photos, not your library", systemImage: "testtube.2")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Brand.ink)
                        }
                        if let storage {
                            StorageHeroCard(storage: storage, photos: measuredPhotos, showInfo: { showScoreInfo = true }) {
                                whatsUsingLink(storage)
                            }
                        }
                        if model.isScanning {
                            scanning
                        } else if model.rescue == nil {
                            start
                        }
                        problems
                        if let rescue = model.rescue {
                            finds(rescue)
                        }
                        RecentlyDeletedCard { showRecentlyDeleted = true }
                        if let rescue = model.rescue {
                            footer(rescue)
                        }
                        promise
                    }
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { dock }
            .navigationTitle("TidyAway")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 8) {
                        BrandMark(size: 30)
                        Text("TidyAway").font(.title3.weight(.heavy)).foregroundStyle(Brand.ink)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("TidyAway")
                    .accessibilityAddTraits(.isHeader)
                }
                // The brand on the left is the title; the bar keeps its name for VoiceOver and tests.
                ToolbarItem(placement: .principal) {
                    Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: openMore) {
                        Image(systemName: "gearshape")
                    }
                    .tint(Brand.ink)
                    .accessibilityLabel("Settings and more")
                    .accessibilityIdentifier("home-settings")
                }
            }
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .sheet(isPresented: $showRecentlyDeleted, onDismiss: { storage = DeviceStorage.current() }) {
                RecentlyDeletedGuide()
            }
            .sheet(isPresented: $showScoreInfo) {
                if let storage { ScoreInfoSheet(storage: storage) }
            }
            .proSheet($offer, pro: pro)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { storage = DeviceStorage.current() }
            }
            .onAppear { storage = DeviceStorage.current() }
            .task(id: "\(insights.revision)-\(model.rescue?.snapshot.assets.count ?? 0)-\(model.isScanning)") { await remakeSmart() }
            .task(id: model.rescue?.snapshot.date) { await loadSmartPro() }
            .onChange(of: insights.revision) { Task { await makeSets() } }
            .onChange(of: pro.unlocked) { _, unlocked in
                if unlocked, let rescue = model.rescue { sorter.start(rescue.screenshots.items.map(\.id)) }
            }
        }
    }

    // MARK: - Storage card

    /// Photos and videos on this iPhone from the last check. Sample data has no real sizes; the
    /// App Store pictures use a stand-in share so the card looks as it does on a real library.
    private var measuredPhotos: Int64? {
        guard let rescue = model.rescue, let storage else { return nil }
        if model.isDemo {
            return LaunchFlags.has("--store-pictures") ? Int64(Double(storage.used) * 0.43) : nil
        }
        return min(rescue.libraryLocalBytes, storage.used)
    }

    @ViewBuilder
    private func whatsUsingLink(_ storage: DeviceStorage) -> some View {
        if let rescue = model.rescue {
            let photos = model.isDemo ? 0 : min(rescue.libraryLocalBytes, storage.used)
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

    // MARK: - Before and during a check

    private var start: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Storage full? Get your camera back.")
                .font(.title2.bold())
                .foregroundStyle(Brand.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
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
        .homeCard()
    }

    private var scanning: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Looking through your photos").font(.title3.bold()).foregroundStyle(Brand.ink)
                .accessibilityAddTraits(.isHeader)
            ProgressView(value: model.total > 0 ? Double(model.completed) / Double(model.total) : 0)
                .tint(Brand.primary)
                .accessibilityLabel("\(model.completed.formatted()) of \(model.total.formatted()) checked")
            if model.total > 0 {
                Text("Looking through \(model.completed.formatted()) of \(model.total.formatted())")
                    .font(.subheadline).monospacedDigit().foregroundStyle(Brand.muted)
            }
            if let rescue = model.rescue {
                (Text(rescue.upToBytes.fileSize).font(.title2.weight(.heavy)).foregroundColor(Brand.ink)
                    + Text(" found so far").font(.subheadline).foregroundColor(Brand.muted))
                    .contentTransition(.numericText())
            }
            Text("The biggest finds show up first. You can start clearing them now.")
                .font(.footnote).foregroundStyle(Brand.muted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Stop", role: .cancel) { model.cancel() }
                .buttonStyle(ArchiveOutlineStyle())
        }
        .homeCard()
    }

    @ViewBuilder
    private var problems: some View {
        if let error = model.errorMessage {
            Text(error).font(.subheadline).foregroundStyle(Brand.caution)
        }
        if model.authorization == .denied || model.authorization == .restricted {
            VStack(alignment: .leading, spacing: 8) {
                Text("TidyAway needs access to your photos to find space.").foregroundStyle(Brand.ink)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Ready to tidy

    @ViewBuilder
    private func finds(_ rescue: RescueSummary) -> some View {
        Text("Ready to tidy")
            .font(.title2.weight(.heavy))
            .foregroundStyle(Brand.ink)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
        sectionPills
        if pro.grandfathered && !pro.unlocked && !earlyNoteSeen {
            EarlySupporterNote { earlyNoteSeen = true }
        }
        let all = rows(rescue)
        let shown = all.filter(shows)
        ForEach(TidyRow.Shelf.allCases) { shelf in
            let list = shown.filter { $0.shelf == shelf }
            if !list.isEmpty {
                // On one pill the shelf shows only part of itself, so its total is that part's.
                let plain = list.reduce(Int64(0)) { $0 + $1.bytes }
                let counted = totals?.shelves[shelf.rawValue] ?? plain
                VStack(spacing: 0) {
                    ShelfHeader(shelf: shelf, total: section == .forYou ? counted : plain)
                    ForEach(list) { row in
                        Rectangle().fill(Brand.hairline).frame(height: 1)
                        rowButton(row, rescue)
                    }
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Brand.cardEdge, lineWidth: 1))
            }
        }
        if section == .smart && shown.isEmpty && !insights.running {
            Text("No smart groups yet. They appear as TidyAway looks through your photos.")
                .font(.subheadline).foregroundStyle(Brand.muted)
        }
        if insights.running && section != .byType {
            Label("Smart groups grow as TidyAway looks through your photos: \(insights.done.formatted()) of \(insights.total.formatted()). On this \(Device.name) only.",
                  systemImage: "sparkles")
                .font(.footnote).foregroundStyle(Brand.muted)
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

    private func shows(_ row: TidyRow) -> Bool {
        switch section {
        case .forYou: return true
        case .smart: return row.kind != .type
        case .byType: return row.kind == .type
        }
    }

    /// The person's own numbers for the Pro sheet: "Found on this iPhone: 1,286 items, about 3.4 GB."
    private func found(_ row: TidyRow) -> String? {
        var parts: [String] = []
        if row.id == "smart-screenshots" {
            parts.append("\(row.size) \(row.count)")
        } else {
            if !row.count.isEmpty { parts.append(row.count) }
            if row.bytes > 0 { parts.append("about \(row.size)") }
        }
        guard !parts.isEmpty else { return nil }
        return "Found on this \(Device.name): \(parts.joined(separator: ", ")). You still approve every one."
    }

    private func locked(_ row: TidyRow) -> Bool {
        guard let feature = row.feature else { return false }
        return !pro.allows(feature)
    }

    /// A row opens its list. A Pro row someone can't open yet shows what it is on a half sheet instead.
    @ViewBuilder
    private func rowButton(_ row: TidyRow, _ rescue: RescueSummary) -> some View {
        if locked(row) {
            Button {
                offer = ProOffer(id: row.id, title: row.title, what: row.what, found: found(row), symbol: row.symbol)
            } label: {
                TidyRowLabel(row: row, locked: true)
            }
            .buttonStyle(PressableStyle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Available in TidyAway Pro")
            .accessibilityIdentifier(row.id)
        } else {
            NavigationLink { destination(row, rescue) } label: {
                TidyRowLabel(row: row, locked: false,
                             yours: row.feature == .smartPicks && pro.grandfathered && !pro.unlocked)
            }
            .buttonStyle(PressableStyle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(row.id)
        }
    }

    @ViewBuilder
    private func destination(_ row: TidyRow, _ rescue: RescueSummary) -> some View {
        switch row.id {
        case "row-duplicates": duplicatesList
        case "row-videos": videosList(rescue)
        case "row-screenshots": screenshotsList(rescue)
        case "row-more": MoreTypesView(types: rescue.otherTypes, model: model)
        case "smart-archived": ArchivedOnPhoneView(model: model, places: archived)
        case "smart-best": BestShotsView(model: model, sets: sets)
        case "smart-screenshots": ScreenshotGroupsView(model: model, items: rescue.screenshots.items)
        default:
            if let group = smart.first(where: { "smart-\($0.id)" == row.id }) {
                smartList(group)
            } else {
                Text("Nothing here right now.").foregroundStyle(.secondary)
            }
        }
    }

    /// Every group, once, on the shelf that says how safe it is to clear.
    private func rows(_ rescue: RescueSummary) -> [TidyRow] {
        var list: [TidyRow] = []

        // Safe to clear
        let copies = rescue.duplicateCopies
        list.append(TidyRow(id: "row-duplicates", shelf: .safe, kind: .type, title: "Duplicates",
                            detail: "Extra copies. One always stays.",
                            size: copies == 0 ? "None" : rescue.duplicateBytes.fileSize,
                            count: copies == 0 ? "" : "\(copies.formatted()) \(copies == 1 ? "copy" : "copies")",
                            symbol: "square.on.square", bytes: rescue.duplicateBytes))
        let shots = rescue.screenshots
        list.append(TidyRow(id: "row-screenshots", shelf: .safe, kind: .type, title: "Screenshots",
                            detail: "Captures you may be done with",
                            size: size(shots.localBytes, shots.iCloudBytes, empty: shots.items.isEmpty),
                            count: count(shots.items.count, "item", shots.localBytes, shots.iCloudBytes),
                            symbol: "camera.viewfinder", bytes: shots.localBytes))
        let archivedCount = Set(archived.flatMap(\.records).compactMap(\.photoID)).count
        if archivedCount > 0 {
            let bytes = archived.reduce(0) { $0 + $1.bytes }
            list.append(TidyRow(id: "smart-archived", shelf: .safe, kind: .pro, title: "Already archived",
                                detail: "A verified copy exists",
                                size: bytes.fileSize, count: "\(archivedCount.formatted()) \(archivedCount == 1 ? "item" : "items")",
                                symbol: "archivebox", bytes: bytes, feature: .smartPro,
                                what: "lists photos still on this \(Device.name) that already have a verified copy in your archive, so you can free them knowing the copy is checked again first."))
        }

        // Worth a look
        for group in smart {
            let number = group.items.count
            list.append(TidyRow(id: "smart-\(group.id)", shelf: .look, kind: .smart, title: group.title,
                                detail: group.why, size: group.bytes.fileSize,
                                count: "\(number.formatted()) \(number == 1 ? "item" : "items")",
                                symbol: group.symbol, bytes: group.items.reduce(0) { $0 + $1.localBytes },
                                feature: .smartPicks, what: Self.what[group.id] ?? "gathers these photos on this \(Device.name), so you can review them in one list."))
        }
        if !sets.isEmpty {
            let extras = sets.flatMap(\.extras)
            let bytes = extras.reduce(0) { $0 + $1.localBytes }
            list.append(TidyRow(id: "smart-best", shelf: .look, kind: .pro, title: "Best shots",
                                detail: "Best shot marked, with the reason",
                                size: bytes > 0 ? bytes.fileSize : "\(sets.count.formatted())",
                                count: "\(sets.count.formatted()) look-alike \(sets.count == 1 ? "set" : "sets")",
                                symbol: "star.square.on.square", bytes: bytes, feature: .smartPro,
                                what: "picks the photo to keep in each set of look-alike shots and says why: the sharpest, eyes open, the clearest faces. You only decide what goes."))
        }
        if !shots.items.isEmpty {
            list.append(TidyRow(id: "smart-screenshots", shelf: .look, kind: .pro, title: "Screenshots, read",
                                detail: sortedDetail(rescue), size: shots.items.count.formatted(), count: "screenshots",
                                symbol: "text.viewfinder", bytes: 0, feature: .smartPro,
                                what: "reads the words in your screenshots on this \(Device.name) and sorts them: login codes, expired tickets, receipts, chats and maps. The words are never kept or sent."))
        }
        let kinds = rescue.otherTypes.filter { !$0.items.isEmpty }.count
        list.append(TidyRow(id: "row-more", shelf: .look, kind: .type, title: "More types",
                            detail: "GIFs, bursts, Live Photos and more",
                            size: rescue.otherBytes.fileSize,
                            count: kinds == 0 ? "" : "\(kinds) \(kinds == 1 ? "kind" : "kinds")",
                            symbol: "square.grid.2x2", bytes: rescue.otherBytes))

        // Move it, keep it
        list.append(TidyRow(id: "row-videos", shelf: .move, kind: .type, title: "Large videos",
                            detail: "Best copied to your archive first",
                            size: size(rescue.videoBytes, rescue.videoICloudBytes, empty: rescue.videos.isEmpty),
                            count: count(rescue.videos.count, "video", rescue.videoBytes, rescue.videoICloudBytes),
                            symbol: "video", bytes: rescue.videoBytes, chip: "Copy first"))
        return list
    }

    /// What each smart pick does, for the Pro sheet. Follows the group's name.
    private static let what: [String: String] = [
        "look-alike": "groups photos taken seconds apart that look nearly the same and keeps the sharpest, so you only decide what goes.",
        "blurry": "gathers the photos that are out of focus or shaken, measured on this \(Device.name), so you can review them in one list.",
        "accidental": "gathers pocket, floor and ceiling shots and videos under 2 seconds, so you can clear them in one pass.",
        "dark": "gathers photos so dark that almost nothing shows, so you can review them in one list.",
        "expired": "finds photos of receipts, tickets and parking spots more than 3 months old, recognized on this \(Device.name).",
        "old-screenshots": "lists screenshots more than 30 days old, leaving recent ones out.",
        "screens": "finds photos of screens, whiteboards and slides, the kind taken as a reminder."
    ]

    /// Phone space first; items only in iCloud show their iCloud size.
    private func size(_ local: Int64, _ iCloud: Int64, empty: Bool) -> String {
        if empty { return "None" }
        return local > 0 ? local.fileSize : iCloud.fileSize
    }

    private func count(_ number: Int, _ noun: String, _ local: Int64, _ iCloud: Int64) -> String {
        guard number > 0 else { return "" }
        let items = "\(number.formatted()) \(noun)\(number == 1 ? "" : "s")"
        if iCloud == 0 { return items }
        return local == 0 ? "\(items) · in iCloud" : "\(items) · +\(iCloud.fileSize) in iCloud"
    }

    private func sortedDetail(_ rescue: RescueSummary) -> String {
        let ids = rescue.screenshots.items.map(\.id)
        guard pro.allows(.smartPro) else { return "Sorted by what they say" }
        if sorter.running { return "Reading \(sorter.done.formatted()) of \(sorter.total.formatted())" }
        let codes = ids.filter { sorter.kinds[$0] == .loginCode }.count
        return codes > 0 ? "\(codes.formatted()) login codes found" : "Read on this \(Device.name)"
    }

    private func smartList(_ group: CleanupGroup) -> some View {
        CleanupListView(title: group.id == "for-you" ? "Suggested for you" : group.title, guidance: group.info,
                        items: group.items, source: group.id == "for-you" ? "Suggested for you" : group.title,
                        allowsRemoval: true, model: model, sets: group.sets)
    }

    /// Remakes the smart groups from the scan and the recognition results, off the main thread.
    private func remakeSmart() async {
        guard !model.isScanning, let rescue = model.rescue else { return }
        guard !model.isDemo else {
            await remakeTotals()
            return
        }
        let snapshot = rescue.snapshot
        insights.start(snapshot.assets)
        let found = insights.insights
        let made = await Task.detached(priority: .utility) {
            let facts = AssetFacts.all(for: snapshot.assets)
            return CleanupGrouper.groups(in: snapshot, insights: found, facts: facts)
        }.value
        smart = made
        // Check-ins compare against the latest totals, including in the background.
        if let rescue = model.rescue { CheckInCenter.shared.noteCheck(groups: made, rescue: rescue) }
        await remakeTotals()
    }

    /// Photos already archived and the look-alike sets, read off the main thread.
    private func loadSmartPro() async {
        guard !model.isDemo, let rescue = model.rescue else { return }
        archived = await Task.detached(priority: .utility) { ArchivedOnPhone.load() }.value
        await makeSets()
        if pro.allows(.smartPro) { sorter.start(rescue.screenshots.items.map(\.id)) }
    }

    private func makeSets() async {
        guard !model.isDemo, let snapshot = model.rescue?.snapshot else { return }
        let found = insights.insights
        sets = await Task.detached(priority: .utility) {
            CleanupGrouper.keepSets(in: snapshot.assets, insights: found, facts: AssetFacts.all(for: snapshot.assets))
        }.value
        await remakeTotals()
    }

    /// The docked total and the shelf totals, counting each item once.
    private func remakeTotals() async {
        guard let rescue = model.rescue else {
            totals = nil
            return
        }
        let groups = smart, places = archived, kept = sets
        totals = await Task.detached(priority: .utility) {
            TidyTotals.make(rescue: rescue, smart: groups, archived: places, sets: kept)
        }.value
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

    // MARK: - Dock

    /// Docked above the tab bar: the estimate, one main button, and the way into the Storage Checkup.
    private var dock: some View {
        VStack(spacing: 8) {
            if !model.isScanning, let rescue = model.rescue {
                let about = totals?.total ?? rescue.upToBytes
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        estimate(about)
                        Spacer(minLength: 8)
                        estimateChip
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        estimate(about)
                        estimateChip
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                review(rescue)
            } else if !model.isScanning {
                Button("Free up space") { model.startDuplicateScan() }
                    .buttonStyle(ArchiveButtonStyle())
                    .accessibilityHint("Checks photos on this \(Device.name)")
                    .accessibilityIdentifier("free-up-space")
            }
            NavigationLink { StorageCheckupView() } label: {
                HStack(spacing: 6) {
                    Text("Storage Checkup").font(.subheadline.weight(.bold)).foregroundStyle(ArchiveStyle.link)
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(ArchiveStyle.link)
                    Text("guided steps for apps and Messages").font(.footnote).foregroundStyle(Brand.muted)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("storage-checkup")
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Rectangle().fill(Brand.hairline).frame(height: 1) }
    }

    private func estimate(_ bytes: Int64) -> some View {
        (Text("About \(bytes.fileSize)").font(.title2.weight(.heavy)).foregroundColor(Brand.ink)
            + Text(" you could free").font(.subheadline).foregroundColor(Brand.muted))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityIdentifier("hero-bytes")
    }

    private var estimateChip: some View {
        Text("ESTIMATE")
            .font(.caption2.weight(.heavy)).tracking(0.6)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(Brand.muted)
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Brand.muted, lineWidth: 1))
            .accessibilityLabel("Estimate")
    }

    /// One main button. It opens the suggestion (the safest smart picks together) for people who
    /// have smart picks, otherwise the safest find first, then the biggest.
    @ViewBuilder
    private func review(_ rescue: RescueSummary) -> some View {
        Group {
            if pro.allows(.smartPicks), let pick = CleanupGrouper.suggestion(from: smart) {
                NavigationLink("Review and free space") { smartList(pick) }
                    .accessibilityHint("Suggested for you: \(pick.why)")
            } else if rescue.duplicateCopies > 0 {
                NavigationLink("Review and free space") { duplicatesList }
                    .accessibilityHint("Opens Duplicates")
            } else if !rescue.videos.isEmpty {
                NavigationLink("Review and free space") { videosList(rescue) }
                    .accessibilityHint("Opens Large videos")
            } else if !rescue.screenshots.items.isEmpty {
                NavigationLink("Review and free space") { screenshotsList(rescue) }
                    .accessibilityHint("Opens Screenshots")
            }
        }
        .buttonStyle(ArchiveButtonStyle())
        .accessibilityIdentifier("review-next")
    }

    // MARK: - Page bottom

    private var promise: some View {
        Label {
            Text("Favorites are never offered. Nothing is deleted until you approve it and iOS confirms. Get back restores a copy.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "checkmark.shield").foregroundStyle(Brand.safe)
        }
        .font(.footnote)
        .foregroundStyle(Brand.muted)
        .accessibilityIdentifier("home-promise")
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
                Text("If it stays very large, updating iOS usually helps.")
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
