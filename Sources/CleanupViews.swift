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
    @State private var selected: Set<String> = []
    @State private var agreed = false
    @State private var working = false
    @State private var message: String?
    @State private var result: RemovedResult?

    private var selectable: [AssetRecord] { items.filter { !$0.favorite } }
    private var selectedRecords: [AssetRecord] { selectable.filter { selected.contains($0.id) } }
    private var selectedBytes: Int64 { selectedRecords.reduce(0) { $0 + $1.displayBytes } }
    private var allSelected: Bool { !selectable.isEmpty && selectedRecords.count == selectable.count }

    var body: some View {
        List {
            if items.isEmpty {
                Text("Nothing here right now.").foregroundStyle(.secondary)
            }
            ForEach(items) { asset in
                AssetRow(asset: asset, selectable: allowsRemoval, selected: selected.contains(asset.id)) {
                    toggle(asset)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let guidance {
                ToolbarItem(placement: .topBarTrailing) { InfoButton(title: title, text: guidance) }
            }
            if allowsRemoval && !selectable.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(allSelected ? "Deselect all" : "Select all") {
                        selected = allSelected ? [] : Set(selectable.map(\.id))
                        agreed = false
                    }
                    .accessibilityIdentifier("select-all")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if allowsRemoval && !items.isEmpty {
                VStack(spacing: 0) {
                    if !selectedRecords.isEmpty {
                        // Copy them off first: archiving removes nothing, and the copy screen checks everything.
                        Button {
                            ArchiveBasket.shared.send(selectedRecords)
                        } label: {
                            Label("Archive \(selectedRecords.count.formatted()) first · \(selectedBytes.fileSize)",
                                  systemImage: "externaldrive.badge.plus")
                        }
                        .buttonStyle(ArchiveOutlineStyle())
                        .disabled(working)
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .background(.regularMaterial)
                        .accessibilityIdentifier("archive-selected")
                    }
                    RemovalBar(count: selectedRecords.count, bytes: selectedBytes,
                               fullText: RemovalDisclosure.items(count: selectedRecords.count, from: source),
                               working: working, message: message, agreed: $agreed, delete: delete)
                }
            }
        }
        .sheet(item: $result) { RescueResultView(result: $0) }
        .onChange(of: selected) { message = nil }
    }

    private func toggle(_ asset: AssetRecord) {
        guard allowsRemoval, !asset.favorite else { return }
        if selected.contains(asset.id) { selected.remove(asset.id) } else { selected.insert(asset.id) }
        agreed = false
    }

    private func delete() {
        let records = selectedRecords
        let bytes = selectedBytes
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

/// Exact duplicates: one copy of each group is kept and labelled; the extra copies can be selected.
struct DuplicatesListView: View {
    @ObservedObject var model: DashboardModel
    @State private var selected: Set<String> = []
    @State private var agreed = false
    @State private var working = false
    @State private var message: String?
    @State private var result: RemovedResult?

    private var groups: [DuplicateGroup] { model.rescue?.duplicateGroups ?? [] }
    private var extras: [String] { model.rescue?.duplicatePlans.flatMap(\.removeIDs) ?? [] }
    private var selectedPlans: [DuplicateRemovalPlan] {
        groups.compactMap { DuplicateRemovalPlan(group: $0, onlyRemoving: selected) }
    }
    private var selectedCount: Int { selectedPlans.reduce(0) { $0 + $1.removeIDs.count } }
    private var selectedBytes: Int64 { selectedPlans.reduce(0) { $0 + $1.removeBytes } }
    private var allSelected: Bool { !extras.isEmpty && selectedCount == extras.count }

    var body: some View {
        List {
            if groups.isEmpty {
                Text("No exact duplicates found among the photos and videos on this iPhone.")
                    .foregroundStyle(.secondary)
            }
            ForEach(groups) { group in
                let plan = DuplicateRemovalPlan(group: group)
                Section("\(group.assets.count) identical · keeping 1") {
                    ForEach(group.assets) { asset in
                        let isExtra = plan?.removeIDs.contains(asset.id) ?? false
                        AssetRow(asset: asset, selectable: isExtra, selected: selected.contains(asset.id),
                                 note: asset.id == plan?.keepID ? "Keeping this one" : nil) {
                            guard isExtra else { return }
                            if selected.contains(asset.id) { selected.remove(asset.id) } else { selected.insert(asset.id) }
                            agreed = false
                        }
                    }
                }
            }
        }
        .navigationTitle("Duplicates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                InfoButton(title: "Duplicates",
                           text: "Exact duplicates match byte for byte, including Live Photo motion and edits. TidyAway always keeps one copy of each, keeps favorites, and checks every copy again just before removal.")
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
            }
        }
        .sheet(item: $result) { RescueResultView(result: $0) }
        .onChange(of: selected) { message = nil }
    }

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

/// One photo or video in a cleanup list.
struct AssetRow: View {
    let asset: AssetRecord
    let selectable: Bool
    let selected: Bool
    var note: String? = nil
    let toggle: () -> Void

    var body: some View {
        if selectable {
            Button(action: toggle) { content }
                .buttonStyle(.plain)
                .accessibilityLabel(selected ? "Selected \(asset.filename)" : "Select \(asset.filename)")
                .accessibilityIdentifier("select-\(asset.id)")
        } else {
            // Kept and review-only items aren't buttons, so they don't look tappable.
            content
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("kept-\(asset.id)")
        }
    }

    private var content: some View {
            HStack(spacing: 12) {
                if selectable {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(selected ? Brand.primary : Color.secondary)
                        .accessibilityHidden(true)
                } else if asset.favorite {
                    Image(systemName: "heart.fill").font(.title3).foregroundStyle(Color.secondary)
                        .frame(width: 28).accessibilityHidden(true)
                }
                AssetThumbnail(assetID: asset.id)
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
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
    }
}

/// Shown after a deletion: the space comes back once Recently Deleted is emptied.
struct RescueResultView: View {
    let result: RemovedResult
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
