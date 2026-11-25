import Photos
import SwiftUI

// The Smart Pro screens. Their rows sit on the Free up shelves (see FreeUpView), each with a PRO badge.

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
    @State private var preview: PreviewRequest?
    /// Best shots only looks here; choosing what goes happens on the review list.
    @State private var nothing: Set<String> = []

    private var everyMember: [AssetRecord] { sets.flatMap { members($0) } }
    private var bestNotes: [String: String] {
        var notes: [String: String] = [:]
        for set in sets {
            let keep = keeper(set)
            notes[keep.id] = "★ Best shot: \(keep.reason)"
        }
        return notes
    }

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
                                .previewMenu(assetID: record.id,
                                             tick: record.id == keep.id ? nil : PreviewTick(title: "Keep this photo instead", action: { chosen[set.id] = record.id }),
                                             open: { preview = PreviewRequest(assetID: record.id) },
                                             info: { preview = PreviewRequest(assetID: record.id, showInfo: true) })
                                .accessibilityLabel(record.id == keep.id ? "Kept photo" : "Keep this photo instead")
                                .accessibilityHint("Touch and hold to look at it full screen")
                                .accessibilityIdentifier(record.id == keep.id ? "best-kept" : "best-other")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Text("★ Keeping: \(keep.reason)").font(.footnote.weight(.semibold)).foregroundStyle(ArchiveStyle.safeText)
                }
            }
        }
        .fullScreenCover(item: $preview) { request in
            PhotoPreview(title: "Best shots", items: everyMember, request: request, selectable: [],
                         notes: bestNotes, selected: $nothing)
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
