import Photos
import SwiftUI

/// The project rule: originals are only removed from the iPhone after archiving once copy and
/// put-back have been proven on a physical iPhone. The owner switches this on after that test.
enum RemovalAfterArchive {
    static let enabled = false
}

/// What an archive run just did, for the completion screen and the follow-up removal.
struct ArchiveCompletion: Identifiable {
    let id = UUID()
    let items: [ArchiveItem]
    let bytes: Int64
    let place: String
    let driveFolderID: String?

    /// Photos-library items that were archived; files from Files are never removed.
    var photoIDs: [String] {
        items.compactMap { item in
            if case let .photo(id, _) = item.source { return id }
            return nil
        }
    }
    var count: Int { items.count }
}

/// Removes originals from Apple Photos after a verified archive, with the usual sign-off and
/// Apple's own confirmation. Favorites are never removed.
struct ArchivedRemovalView: View {
    let done: ArchiveCompletion
    @ObservedObject var model: DashboardModel
    @State private var agreed = false
    @State private var working = false
    @State private var message: String?
    @State private var result: RemovedResult?
    @Environment(\.dismiss) private var dismiss

    private var removable: [String] {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: done.photoIDs, options: nil)
        var ids: [String] = []
        assets.enumerateObjects { asset, _, _ in if !asset.isFavorite { ids.append(asset.localIdentifier) } }
        return ids
    }

    var body: some View {
        List {
            Section {
                Text("\(done.count) \(done.count == 1 ? "item was" : "items were") copied to \(done.place) and checked against the originals.")
                if removable.count < done.photoIDs.count {
                    Text("Favorites stay on your iPhone.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Free up space")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Not now") { dismiss() } }
        }
        .safeAreaInset(edge: .bottom) {
            RemovalBar(count: removable.count, bytes: done.bytes,
                       fullText: "I authorize TidyAway to delete \(removable.count) selected items from Apple Photos. If iCloud Photos is on, these items will also be deleted from iCloud Photos and synced devices. Apple normally keeps deleted items in Recently Deleted for up to 30 days unless they're permanently deleted sooner. A verified full-resolution copy remains in \(done.place).",
                       working: working, message: message, agreed: $agreed, delete: remove)
        }
        .sheet(item: $result, onDismiss: { dismiss() }) { RescueResultView(result: $0) }
    }

    private func remove() {
        let ids = removable
        working = true
        Task {
            let outcome = await model.removeItems(ids, bytes: done.bytes, from: "items archived to \(done.place)")
            working = false
            agreed = false
            switch outcome {
            case let .removed(count, bytes): result = RemovedResult(count: count, bytes: bytes)
            case .cancelled: message = "Cancelled. Nothing was removed."
            case .sample: message = "Sample data. Nothing was removed."
            case .blocked(let reason): message = reason
            }
        }
    }
}
