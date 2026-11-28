import SwiftUI

/// Shared outcome handling for cleanup lists: removed items open the Recently Deleted screen,
/// anything else shows a one-line message in the bar.
private func outcomeMessage(_ outcome: DuplicateRemovalOutcome) -> String? {
    switch outcome {
    case .removed: nil
    case .cancelled: "Cancelled. Nothing was removed."
    case .sample: "Sample data. Nothing was removed."
    case .blocked(let reason): reason
    }
}

struct RemovedResult: Identifiable {
    let id = UUID()
    let count: Int
    let bytes: Int64
}

/// A list of photos or videos, largest first, that people can select and delete in one go.
/// Nothing is pre-selected; favorites can't be selected.
struct CleanupListView: View {
    let title: String
    let guidance: String?
    let items: [AssetRecord]
    /// Where the items came from, for the sign-off text and the activity log.
    let source: String
    let allowsRemoval: Bool
    @ObservedObject var model: DashboardModel
    /// Look-alike sets. Each kept photo is shown first, locked, and is never in `items`.
    var sets: [KeepSet] = []
    @State private var selected: Set<String> = []
    @State private var agreed = false
    @State private var working = false
    @State private var message: String?
    @State private var result: RemovedResult?
    @State private var preview: PreviewRequest?
    /// Set when some selected items have no verified archive copy: the alert before Apple's confirmation.
    @State private var backup: BackupCheck?
    @EnvironmentObject private var pro: ProStore
    @State private var ratingTrigger = 0

    /// What can be selected, worked out once per list of items rather than on every tap.
    @State private var cache = CleanupSelectionCache()
    private var derived: CleanupSelection { cache.selection(items: items, sets: sets) }

    private func row(_ asset: AssetRecord, selectable: Bool, note: String? = nil) -> some View {
        AssetRow(asset: asset, selectable: selectable, selected: selected.contains(asset.id), note: note,
                 preview: { preview = PreviewRequest(assetID: asset.id) },
                 info: { preview = PreviewRequest(assetID: asset.id, showInfo: true) }) {
            toggle(asset)
        }
    }
    /// Only worked out when the selection is acted on; the body uses the counts below.
    private var selectedRecords: [AssetRecord] { derived.records(selected) }

    var body: some View {
        let derived = self.derived
        let selectedCount = derived.count(of: selected)
        let allSelected = derived.allSelected(selected)
        return List {
            Group {
            if items.isEmpty {
                Text("Nothing here right now.").foregroundStyle(.secondary)
            } else {
                PreviewHint(canSelect: allowsRemoval)
            }
            if sets.isEmpty {
                ForEach(items) { asset in
                    row(asset, selectable: allowsRemoval)
                }
            } else {
                ForEach(sets) { set in
                    Section("\(set.extras.count + 1) look alike · keeping 1") {
                        row(set.keep, selectable: false, note: "Keeping this one: \(set.because)")
                        ForEach(set.extras) { asset in
                            row(asset, selectable: allowsRemoval)
                        }
                    }
                }
                let rest = derived.rest
                if !rest.isEmpty {
                    Section("Blurry, accidental and dark") {
                        ForEach(rest) { asset in
                            row(asset, selectable: allowsRemoval)
                        }
                    }
                }
            }
            }
            .hiddenBehindPreview(preview != nil)
        }
        .fullScreenCover(item: $preview) { request in
            PhotoPreview(title: title, items: derived.previewItems, request: request,
                         selectable: allowsRemoval ? derived.selectableIDs : [], notes: derived.keptNotes,
                         selected: $selected, changed: { agreed = false })
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let guidance {
                ToolbarItem(placement: .topBarTrailing) { InfoButton(title: title, text: guidance) }
            }
            if allowsRemoval && !derived.selectable.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(allSelected ? "Deselect all" : "Select all") {
                        selected = allSelected ? [] : derived.selectableIDs
                        agreed = false
                    }
                    .accessibilityIdentifier("select-all")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if allowsRemoval && !items.isEmpty {
                VStack(spacing: 0) {
                    RemovalBar(count: selectedCount, bytes: derived.bytes(of: selected),
                               fullText: RemovalDisclosure.items(count: selectedCount, from: source),
                               working: working, message: message, agreed: $agreed, delete: delete)
                    if selectedCount > 0 {
                        // The alternative to deleting: copy them off with Archive. Archiving removes nothing.
                        Button {
                            ArchiveBasket.shared.send(selectedRecords)
                        } label: {
                            Label("Or archive \(selectedCount == 1 ? "it" : "them") instead", systemImage: "externaldrive.badge.plus")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.borderless)
                        .tint(ArchiveStyle.link)
                        .disabled(working)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .background(.regularMaterial)
                        .accessibilityIdentifier("archive-selected")
                    }
                }
                .hiddenBehindPreview(preview != nil)
            }
        }
        .sheet(item: $result, onDismiss: { ratingTrigger += 1 }) { RescueResultView(result: $0) }
        .fullScreenCover(item: $backup) { check in
            BackupAlert(check: check,
                        copyFirst: {
                            // Only the items without a copy go to Archive. Nothing is deleted.
                            backup = nil
                            agreed = false
                            let items = check.notBackedUp
                            // Once the alert has closed, the same hand-over as "Or archive them instead".
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 350_000_000)
                                ArchiveBasket.shared.send(items)
                            }
                        },
                        deleteAnyway: {
                            backup = nil
                            remove()
                        },
                        // Tapping outside: the alert closes and nothing else happens. Nothing is deleted.
                        cancel: { backup = nil })
                .presentationBackground(.clear)
        }
        .asksForRating(when: ratingTrigger)
        .onChange(of: selected) { message = nil }
    }

    private func toggle(_ asset: AssetRecord) {
        guard allowsRemoval, !asset.favorite, !derived.kept.contains(asset.id) else { return }
        if selected.contains(asset.id) { selected.remove(asset.id) } else { selected.insert(asset.id) }
        agreed = false
    }

    /// Delete was tapped, with the sign-off ticked. Before Apple's confirmation, check whether every
    /// selected item has a verified archive copy; if some don't, ask first. Every time.
    private func delete() {
        let records = selectedRecords
        let sample = model.isDemo
        let unlimited = pro.allows(.unlimitedArchive)
        working = true
        Task {
            // Sample items have no archive copies. The archive list and Photos are read off the main
            // thread. An item counts only while its copy still matches it (edited since: not backed up)
            // and while that copy is still at its destination (gone or out of reach: not backed up).
            var archived: Set<String> = []
            if !sample {
                archived = await BackupLedger.verifiedPhotoIDs(among: records.map(\.id))
            }
            working = false
            if var check = BackupCheck.alert(for: .list, selected: records, archived: archived) {
                // On a free plan, say in the alert when Copy first can't fit in what is left of 5 GB.
                if !unlimited, !sample {
                    let used = await FreeArchiveBudget.usedNow()
                    check.freeLeft = max(0, ProStore.freeArchiveBytes - used)
                }
                backup = check
            } else {
                remove()
            }
        }
    }

    /// Hands the selection to Photos, which shows Apple's own confirmation.
    private func remove() {
        let records = selectedRecords
        let bytes = derived.bytes(of: selected)
        guard !records.isEmpty else { return }
        working = true
        Task {
            let outcome = await model.removeItems(records.map(\.id), bytes: bytes, from: source)
            working = false
            agreed = false
            if case let .removed(count, removedBytes) = outcome {
                selected = []
                result = RemovedResult(count: count, bytes: removedBytes)
            } else {
                message = outcomeMessage(outcome)
            }
        }
    }
}

/// What a cleanup list can select. Built once per list of items, then every tap is a lookup.
/// Select all never includes a kept photo or a favorite.
struct CleanupSelection {
    /// Items that can be ticked, in list order.
    let selectable: [AssetRecord]
    let selectableIDs: Set<String>
    /// The photo kept in each look-alike set.
    let kept: Set<String>
    /// Items outside the look-alike sets, shown under their own heading.
    let rest: [AssetRecord]
    /// Everything the viewer can swipe through, in the order the list shows it.
    let previewItems: [AssetRecord]
    let keptNotes: [String: String]
    private let sizes: [String: Int64]

    init(items: [AssetRecord], sets: [KeepSet]) {
        let kept = Set(sets.map(\.keep.id))
        let inSets = Set(sets.flatMap(\.extras).map(\.id))
        let selectable = items.filter { !$0.favorite && !kept.contains($0.id) }
        let rest = items.filter { !inSets.contains($0.id) }
        self.kept = kept
        self.selectable = selectable
        self.rest = rest
        selectableIDs = Set(selectable.map(\.id))
        previewItems = sets.isEmpty ? items : sets.flatMap { [$0.keep] + $0.extras } + rest
        keptNotes = Dictionary(sets.map { ($0.keep.id, "Keeping this one: \($0.because)") }, uniquingKeysWith: { first, _ in first })
        sizes = Dictionary(selectable.map { ($0.id, $0.displayBytes) }, uniquingKeysWith: { first, _ in first })
    }

    /// How many of the selected items can be removed.
    func count(of selected: Set<String>) -> Int {
        selected.reduce(0) { selectableIDs.contains($1) ? $0 + 1 : $0 }
    }
    func bytes(of selected: Set<String>) -> Int64 {
        selected.reduce(0) { $0 + (sizes[$1] ?? 0) }
    }
    /// The selected items that can be removed, in list order.
    func records(_ selected: Set<String>) -> [AssetRecord] {
        selectable.filter { selected.contains($0.id) }
    }
    func allSelected(_ selected: Set<String>) -> Bool {
        !selectable.isEmpty && count(of: selected) == selectable.count
    }
}

/// Holds one `CleanupSelection` until the list is given different items.
final class CleanupSelectionCache {
    private var items: [AssetRecord] = []
    private var sets: [KeepSet] = []
    private var cached: CleanupSelection?
    /// How many times the selection was worked out. Tests read it.
    private(set) var builds = 0

    func selection(items: [AssetRecord], sets: [KeepSet]) -> CleanupSelection {
        if let cached, Self.same(items, self.items), Self.same(sets, self.sets) { return cached }
        let made = CleanupSelection(items: items, sets: sets)
        self.items = items
        self.sets = sets
        cached = made
        builds += 1
        return made
    }

    /// Arrays are values, so the same storage means the same contents. Holding on to the last
    /// arrays keeps their storage from being reused for different items.
    private static func same<Element>(_ lhs: [Element], _ rhs: [Element]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        guard !lhs.isEmpty else { return true }
        return lhs.withUnsafeBufferPointer { left in
            rhs.withUnsafeBufferPointer { right in left.baseAddress == right.baseAddress }
        }
    }
}

extension DuplicateGroup {
    /// The kept copy first, then the others in the order they came. A stable, valid ordering
    /// (sorting with "a is the kept one" alone is not one, and can shuffle the list).
    static func keptFirst(_ assets: [AssetRecord], keep: String?) -> [AssetRecord] {
        assets.filter { $0.id == keep } + assets.filter { $0.id != keep }
    }
}

/// Exact duplicates: one copy of each group is kept and labelled; the extra copies can be selected.
struct DuplicatesListView: View {
    @ObservedObject var model: DashboardModel
    @State private var selected: Set<String> = []
    @State private var agreed = false
    @State private var working = false
    @State private var message: String?
    @State private var result: RemovedResult?
    @State private var preview: PreviewRequest?
    @State private var ratingTrigger = 0

    private var groups: [DuplicateGroup] { model.rescue?.duplicateGroups ?? [] }
    private var extras: [String] { model.rescue?.duplicatePlans.flatMap(\.removeIDs) ?? [] }
    /// Every copy, the kept one first in each set, as the list shows them.
    private var previewItems: [AssetRecord] {
        groups.flatMap { group -> [AssetRecord] in
            let keep = DuplicateRemovalPlan(group: group)?.keepID
            return DuplicateGroup.keptFirst(group.assets, keep: keep)
        }
    }
    private var keptNotes: [String: String] {
        Dictionary((model.rescue?.duplicatePlans ?? []).map { ($0.keepID, "Keeping this one") }, uniquingKeysWith: { first, _ in first })
    }
    private var selectedPlans: [DuplicateRemovalPlan] {
        groups.compactMap { DuplicateRemovalPlan(group: $0, onlyRemoving: selected) }
    }
    private var selectedCount: Int { selectedPlans.reduce(0) { $0 + $1.removeIDs.count } }
    private var selectedBytes: Int64 { selectedPlans.reduce(0) { $0 + $1.removeBytes } }
    private var allSelected: Bool { !extras.isEmpty && selectedCount == extras.count }

    var body: some View {
        List {
            Group {
            if groups.isEmpty {
                Text("No exact duplicates found among the photos and videos on this \(Device.name).")
                    .foregroundStyle(.secondary)
            } else {
                PreviewHint(canSelect: true)
            }
            ForEach(groups) { group in
                let plan = DuplicateRemovalPlan(group: group)
                Section("\(group.assets.count) identical · keeping 1") {
                    ForEach(DuplicateGroup.keptFirst(group.assets, keep: plan?.keepID)) { asset in
                        let isExtra = plan?.removeIDs.contains(asset.id) ?? false
                        AssetRow(asset: asset, selectable: isExtra, selected: selected.contains(asset.id),
                                 note: asset.id == plan?.keepID ? "Keeping this one" : nil,
                                 preview: { preview = PreviewRequest(assetID: asset.id) },
                                 info: { preview = PreviewRequest(assetID: asset.id, showInfo: true) }) {
                            guard isExtra else { return }
                            if selected.contains(asset.id) { selected.remove(asset.id) } else { selected.insert(asset.id) }
                            agreed = false
                        }
                    }
                }
            }
            }
            .hiddenBehindPreview(preview != nil)
        }
        .fullScreenCover(item: $preview) { request in
            PhotoPreview(title: "Duplicates", items: previewItems, request: request, selectable: Set(extras),
                         notes: keptNotes, selected: $selected, changed: { agreed = false })
        }
        .navigationTitle("Duplicates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                InfoButton(title: "Duplicates",
                           text: "Exact duplicates match byte for byte, including Live Photo motion and edits. In each set the copy that stays is shown first with a lock and \"Keeping this one\"; it can't be selected, and Select all never includes it. Favorites are kept too. Every copy is checked again just before removal.")
            }
            if !extras.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(allSelected ? "Deselect all" : "Select all") {
                        selected = allSelected ? [] : Set(extras)
                        agreed = false
                    }
                    .accessibilityIdentifier("select-all")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !groups.isEmpty {
                RemovalBar(count: selectedCount, bytes: selectedBytes,
                           fullText: RemovalDisclosure.duplicates(count: selectedCount),
                           working: working, message: message, agreed: $agreed, delete: delete)
                    .hiddenBehindPreview(preview != nil)
            }
        }
        .sheet(item: $result, onDismiss: { ratingTrigger += 1 }) { RescueResultView(result: $0) }
        .asksForRating(when: ratingTrigger)
        .onChange(of: selected) { message = nil }
    }

    /// Duplicates skip the "not backed up" check (`DeleteFlow.duplicates`): only extra copies go,
    /// and one byte-identical copy of each always stays on the iPhone.
    private func delete() {
        let plans = selectedPlans
        working = true
        Task {
            let outcome = await model.removeDuplicates(plans)
            working = false
            agreed = false
            if case let .removed(count, bytes) = outcome {
                selected = []
                result = RemovedResult(count: count, bytes: bytes)
            } else {
                message = outcomeMessage(outcome)
            }
        }
    }
}

/// One line at the top of a pick list saying how looking and choosing work.
struct PreviewHint: View {
    let canSelect: Bool

    var body: some View {
        Label(canSelect
              ? "Tap a picture to look at it. Tap the circle to choose it. Touch and hold for a quick look."
              : "Tap a picture to look at it. Touch and hold for a quick look.",
              systemImage: "hand.tap")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier("preview-hint")
    }
}

/// One photo or video in a cleanup list. The picture opens the full-screen preview; the circle and
/// the name choose it. Nothing here deletes.
struct AssetRow: View {
    let asset: AssetRecord
    let selectable: Bool
    let selected: Bool
    var note: String? = nil
    /// Opens the full-screen preview at this item. Nil where there is none.
    var preview: (() -> Void)? = nil
    /// Opens the preview with the file info showing.
    var info: (() -> Void)? = nil
    let toggle: () -> Void

    var body: some View {
        Group {
            if selectable {
                HStack(spacing: 12) {
                    // The circle and the words are one choice to VoiceOver; the picture is its own button.
                    Button(action: toggle) {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(selected ? Brand.primary : Color.secondary)
                            .frame(minWidth: 30, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHidden(true)
                    thumbnail
                    Button(action: toggle) {
                        words
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(selected ? "Selected \(asset.filename)" : "Select \(asset.filename)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("select-\(asset.id)")
                }
            } else {
                // Kept and review-only items can be looked at, never chosen.
                HStack(spacing: 12) {
                    if note != nil {
                        Image(systemName: "lock.fill").font(.title3).foregroundStyle(Brand.safe)
                            .frame(width: 28).accessibilityHidden(true)
                    } else if asset.favorite {
                        Image(systemName: "heart.fill").font(.title3).foregroundStyle(Color.secondary)
                            .frame(width: 28).accessibilityHidden(true)
                    }
                    thumbnail
                    words
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("kept-\(asset.id)")
            }
        }
        .previewMenu(assetID: asset.id, tick: tick, open: preview, info: info)
    }

    private var tick: PreviewTick? {
        selectable ? PreviewTick(title: selected ? "Deselect" : "Select", action: toggle) : nil
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let preview {
            Button(action: preview) {
                AssetThumbnail(assetID: asset.id)
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Brand.onViewer)
                            .padding(4)
                            .background(Brand.viewer.opacity(0.55), in: Circle())
                            .padding(3)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview \(asset.filename)")
            .accessibilityIdentifier("preview-\(asset.id)")
        } else {
            AssetThumbnail(assetID: asset.id)
        }
    }

    private var words: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(asset.filename).lineLimit(1).foregroundStyle(.primary)
            Text(asset.inICloud ? "\(asset.displayBytes.fileSize) · in iCloud"
                 : asset.fingerprint == nil ? "Size unknown" : asset.bytes.fileSize)
                .font(.caption).foregroundStyle(.secondary)
            if let note {
                Text(note).font(.caption.weight(.semibold)).foregroundStyle(Brand.safe)
            } else if asset.favorite {
                Text("Favorite, kept").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Shown after a deletion: the space comes back once Recently Deleted is emptied.
struct RescueResultView: View {
    let result: RemovedResult
    /// Shown first, such as a reminder to check archive copies before emptying Recently Deleted.
    var note: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 54))
                        .foregroundStyle(Brand.safe)
                        .accessibilityHidden(true)
                    Text("Almost there").font(.largeTitle.bold())
                    Text(DuplicateRemovalOutcome.removedMessage(count: result.count, bytes: result.bytes))
                        .font(.title3)
                    if let note {
                        Label(note, systemImage: "exclamationmark.shield.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Brand.caution)
                            .accessibilityIdentifier("result-note")
                    }
                    RecentlyDeletedSteps()
                    Text("Until you do, the items stay recoverable there for 30 days, and so does the space they use.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(24)
            }
            .navigationTitle("Moved to Recently Deleted")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.accessibilityIdentifier("result-done")
                }
            }
        }
    }
}
