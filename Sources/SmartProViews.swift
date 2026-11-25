import Photos
import SwiftUI

/// The Smart Pro cards on Free up: photos already archived, best shots with the reason, and
/// screenshots sorted by what they say. All of it runs on this iPhone. Nothing is selected for you.
struct SmartProSection: View {
    @ObservedObject var model: DashboardModel
    let rescue: RescueSummary
    @EnvironmentObject private var pro: ProStore
    @ObservedObject private var insights = InsightModel.shared
    @ObservedObject private var sorter = ScreenshotSorter.shared
    @State private var archived: [ArchivedPlace] = []
    @State private var sets: [KeepSet] = []
    @State private var showPro = false

    private var archivedCount: Int { Set(archived.flatMap(\.records).compactMap(\.photoID)).count }
    private var archivedBytes: Int64 { archived.reduce(0) { $0 + $1.bytes } }
    private var screenshotIDs: [String] { rescue.screenshots.items.map(\.id) }

    var body: some View {
        if archivedCount > 0 || !sets.isEmpty || !screenshotIDs.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Text("SMART PRO")
                        .font(.caption.weight(.heavy)).tracking(0.7)
                        .foregroundStyle(ArchiveStyle.muted)
                    if !pro.unlocked {
                        Image(systemName: "lock.fill").font(.caption).foregroundStyle(ArchiveStyle.muted)
                    }
                }
                .padding(.top, 4)
                .accessibilityAddTraits(.isHeader)
                if archivedCount > 0 {
                    card(title: "Already archived", detail: "\(archivedCount.formatted()) still on this \(Device.name) · \(archivedBytes.fileSize)",
                         why: "Copies checked", symbol: "checkmark.icloud", cover: archived.first?.records.first?.photoID, id: "smart-archived",
                         info: "Photos still on this \(Device.name) that already have a verified copy in your archive. Before anything is deleted, TidyAway checks every copy again, brings one back to test it, and asks you and then Apple to confirm. Favorites stay. Get back can bring any of them back.") {
                        ArchivedOnPhoneView(model: model, places: archived)
                    }
                }
                if !sets.isEmpty {
                    card(title: "Best shots", detail: "\(sets.count.formatted()) look-alike \(sets.count == 1 ? "set" : "sets")",
                         why: "Keeps the best, says why", symbol: "star.square.on.square", cover: sets.first?.keep.id, id: "smart-best",
                         info: "In each set of look-alike photos, TidyAway picks the one to keep and says why: the sharpest, everyone's eyes open, the clearest faces. It looks at the faces on this \(Device.name) only. Tap another photo to keep it instead. Favorites and edited photos always stay. Nothing is selected until you choose.") {
                        BestShotsView(model: model, sets: sets)
                    }
                }
                if !screenshotIDs.isEmpty {
                    card(title: "Screenshots, read", detail: sortedDetail, why: "Read on this \(Device.name)", symbol: "text.viewfinder",
                         cover: screenshotIDs.first, id: "smart-screenshots",
                         info: "TidyAway reads the words in your screenshots on this \(Device.name) and sorts them: login codes, expired tickets, receipts, chats, maps. The words are never kept, logged or sent; only the group is remembered. Nothing is selected until you choose.") {
                        ScreenshotGroupsView(model: model, items: rescue.screenshots.items)
                    }
                }
            }
            .task(id: rescue.snapshot.date) { await load() }
            .onChange(of: insights.revision) { Task { await makeSets() } }
            .sheet(isPresented: $showPro) {
                NavigationStack {
                    ProUpgradeView()
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Not now") { showPro = false } } }
                }
                .environmentObject(pro)
            }
        } else {
            Color.clear.frame(height: 0)
                .task(id: rescue.snapshot.date) { await load() }
        }
    }

    private var sortedDetail: String {
        guard pro.unlocked else { return "\(screenshotIDs.count.formatted()) screenshots" }
        if sorter.running { return "Reading \(sorter.done.formatted()) of \(sorter.total.formatted())" }
        let codes = screenshotIDs.filter { sorter.kinds[$0] == .loginCode }.count
        return codes > 0 ? "\(codes.formatted()) login codes · \(screenshotIDs.count.formatted()) in all" : "\(screenshotIDs.count.formatted()) screenshots"
    }

    @ViewBuilder
    private func card<Destination: View>(title: String, detail: String, why: String, symbol: String, cover: String?, id: String,
                                         info: String, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        ZStack(alignment: .topTrailing) {
            if pro.unlocked {
                NavigationLink { destination() } label: {
                    ArchiveCard(title: title, detail: detail, coverID: cover, why: why, symbol: symbol)
                }
                .accessibilityIdentifier(id)
            } else {
                Button { showPro = true } label: {
                    ArchiveCard(title: title, detail: detail, coverID: cover, why: "PRO · " + why, symbol: symbol)
                }
                .accessibilityIdentifier(id)
                .accessibilityHint("TidyAway Pro")
            }
            CardInfo(title: title, text: info)
        }
    }

    private func load() async {
        guard !model.isDemo else { return }
        archived = await Task.detached(priority: .utility) { ArchivedOnPhone.load() }.value
        await makeSets()
        if pro.unlocked { sorter.start(screenshotIDs) }
    }

    private func makeSets() async {
        guard !model.isDemo else { return }
        let snapshot = rescue.snapshot
        let found = insights.insights
        sets = await Task.detached(priority: .utility) {
            CleanupGrouper.keepSets(in: snapshot.assets, insights: found, facts: AssetFacts.all(for: snapshot.assets))
        }.value
    }
}

/// Places with photos already archived. Each opens the usual removal after archiving.
struct ArchivedOnPhoneView: View {
    @ObservedObject var model: DashboardModel
    let places: [ArchivedPlace]
    @State private var removal: ArchiveCompletion?

    var body: some View {
        List {
            Section {
                Text("These photos are still on this \(Device.name) and already have a verified copy. Before anything is deleted, TidyAway checks every copy again and brings one back to test it. Then you sign off and Apple asks to confirm.")
                    .font(.subheadline).foregroundStyle(ArchiveStyle.muted)
            }
            Section("Archived to") {
                ForEach(places) { place in
                    Button { removal = ArchivedOnPhone.completion(for: place) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.place).font(.body.weight(.semibold)).foregroundStyle(ArchiveStyle.ink)
                                Text("\(place.records.count.formatted()) \(place.records.count == 1 ? "photo" : "photos")")
                                    .font(.caption).foregroundStyle(ArchiveStyle.muted)
                            }
                            Spacer()
                            Text(place.bytes.fileSize).font(.subheadline.weight(.semibold)).foregroundStyle(Brand.primary)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(ArchiveStyle.muted)
                        }
                    }
                    .disabled(!RemovalAfterArchive.enabled)
                    .accessibilityIdentifier("archived-place")
                }
            }
        }
        .navigationTitle("Already archived")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $removal) { done in
            NavigationStack { ArchivedRemovalView(done: done, model: model) }
        }
    }
}

/// Look-alike sets with the photo to keep and the reason. Tap another to keep it instead.
struct BestShotsView: View {
    @ObservedObject var model: DashboardModel
    let sets: [KeepSet]
    @ObservedObject private var insights = InsightModel.shared
    @State private var scores: [String: ShotScore] = [:]
    @State private var chosen: [String: String] = [:]
    @State private var scored = 0

    /// The original kept photo stays protected when it is a favorite or an edited photo.
    private func isProtected(_ set: KeepSet) -> Bool { set.because != "the sharpest" }

    private func members(_ set: KeepSet) -> [AssetRecord] { [set.keep] + set.extras }

    private func keeper(_ set: KeepSet) -> (id: String, reason: String) {
        if let mine = chosen[set.id] { return (mine, "your pick") }
        if isProtected(set) { return (set.keep.id, set.because) }
        let found = members(set).compactMap { scores[$0.id] }
        guard found.count == members(set).count, let pick = BestShot.pick(found) else { return (set.keep.id, set.because) }
        return pick
    }

    /// The sets as the review list needs them: the chosen photo locked, the rest offered.
    private var refined: [KeepSet] {
        sets.map { set in
            let keep = keeper(set)
            let all = members(set)
            let kept = all.first { $0.id == keep.id } ?? set.keep
            let extras = all.filter { record in
                record.id != kept.id && !record.favorite && !(record.id == set.keep.id && isProtected(set))
            }
            return KeepSet(keep: kept, extras: extras, because: keep.reason)
        }
        .filter { !$0.extras.isEmpty }
    }

    var body: some View {
        List {
            Section {
                Text("In each set, ★ marks the photo that stays and why. Tap another photo to keep it instead. Favorites and edited photos always stay.")
                    .font(.subheadline).foregroundStyle(ArchiveStyle.muted)
                if scored < sets.count {
                    ProgressView(value: Double(scored), total: Double(max(sets.count, 1))) {
                        Text("Looking at faces on this \(Device.name): \(scored) of \(sets.count) sets")
                    }
                    .accessibilityIdentifier("best-progress")
                }
            }
            ForEach(sets) { set in
                Section {
                    let keep = keeper(set)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(members(set)) { record in
                                Button { chosen[set.id] = record.id } label: {
                                    AssetThumbnail(assetID: record.id)
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 10)
                                                .stroke(record.id == keep.id ? Brand.safe : Color.clear, lineWidth: 3)
                                        }
                                        .overlay(alignment: .bottomTrailing) {
                                            if record.id == keep.id {
                                                Image(systemName: "star.fill").font(.caption).foregroundStyle(.white)
                                                    .shadow(radius: 2).padding(4)
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(record.id == keep.id ? "Kept photo" : "Keep this photo instead")
                                .accessibilityIdentifier(record.id == keep.id ? "best-kept" : "best-other")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Text("★ Keeping: \(keep.reason)").font(.footnote.weight(.semibold)).foregroundStyle(ArchiveStyle.safeText)
                }
            }
        }
        .navigationTitle("Best shots")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            let ready = refined
            let count = ready.reduce(0) { $0 + $1.extras.count }
            if count > 0 {
                NavigationLink {
                    CleanupListView(title: "Best shots",
                                    guidance: "The photo kept in each set is shown first with a lock and can't be selected. Nothing is selected until you choose.",
                                    items: ready.flatMap(\.extras), source: "Best shots", allowsRemoval: true, model: model, sets: ready)
                } label: {
                    Text("Review \(count.formatted()) other \(count == 1 ? "photo" : "photos")")
                }
                .buttonStyle(ArchiveButtonStyle())
                .padding(16)
                .background(.regularMaterial)
                .accessibilityIdentifier("best-review")
            }
        }
        .task { await score() }
    }

    /// Four sets at a time, small copies only, on this iPhone.
    private func score() async {
        let sharpness = insights.insights.mapValues(\.sharpness)
        let work = sets.filter { !isProtected($0) }
        scored = sets.count - work.count
        await withTaskGroup(of: [ShotScore].self) { group in
            var waiting = work[...]
            var running = 0
            while true {
                while running < 4, let set = waiting.popFirst() {
                    running += 1
                    let ids = members(set).map(\.id)
                    group.addTask {
                        ids.map { BestShotReader.score($0, sharpness: sharpness[$0] ?? 0) }
                    }
                }
                guard let found = await group.next() else { break }
                running -= 1
                for score in found { scores[score.id] = score }
                scored += 1
                if Task.isCancelled { group.cancelAll() }
            }
        }
    }
}

/// Screenshots sorted by what they say. Each group opens the usual review list.
struct ScreenshotGroupsView: View {
    @ObservedObject var model: DashboardModel
    let items: [AssetRecord]
    @ObservedObject private var sorter = ScreenshotSorter.shared

    private func items(of kind: ScreenshotKind) -> [AssetRecord] {
        items.filter { sorter.kinds[$0.id] == kind }
    }

    var body: some View {
        List {
            Section {
                Text("Read on this \(Device.name). The words are never kept, logged or sent; only the group is remembered.")
                    .font(.subheadline).foregroundStyle(ArchiveStyle.muted)
                if sorter.running {
                    ProgressView(value: Double(sorter.done), total: Double(max(sorter.total, 1))) {
                        Text("Reading screenshots: \(sorter.done.formatted()) of \(sorter.total.formatted())")
                    }
                    .accessibilityIdentifier("screenshots-progress")
                }
            }
            Section {
                ForEach(ScreenshotKind.allCases) { kind in
                    let list = items(of: kind)
                    if !list.isEmpty {
                        NavigationLink {
                            CleanupListView(title: kind.title, guidance: kind.info + " Nothing is selected until you choose.",
                                            items: list, source: "Screenshots: \(kind.title.lowercased())", allowsRemoval: true, model: model)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(kind.title).font(.body.weight(.semibold))
                                    Text(kind.info).font(.caption).foregroundStyle(ArchiveStyle.muted).lineLimit(2)
                                }
                                Spacer()
                                Text("\(list.count.formatted())").font(.subheadline.weight(.semibold)).foregroundStyle(Brand.primary)
                            }
                        }
                        .accessibilityIdentifier("screenshots-\(kind.rawValue)")
                    }
                }
            }
        }
        .navigationTitle("Screenshots, read")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { sorter.start(items.map(\.id)) }
    }
}
