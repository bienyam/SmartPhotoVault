import Photos
import SwiftUI

/// Removing originals after a verified archive. Switched on by the owner on 2026-11-21, after a
/// successful Google Drive copy on the owner's iPhone. Switch to false to hide the step again.
enum RemovalAfterArchive {
    static let enabled = true
}

/// What an archive run just did, for the completion screen and the follow-up removal.
struct ArchiveCompletion: Identifiable {
    let id = UUID()
    let items: [ArchiveItem]
    let bytes: Int64
    let place: String
    let driveFolderID: String?
    /// The saved record of each verified copy, by item. An item without one is never deleted.
    var copies: [String: ArchivedRecord] = [:]

    /// Photos-library items that were archived; files from Files are never removed.
    var photoIDs: [String] {
        items.compactMap { item in
            if case let .photo(id, _) = item.source { return id }
            return nil
        }
    }
    var count: Int { items.count }

    /// Archived Photos items that aren't favorites, with their saved copies.
    var removable: [ArchiveItem] {
        var favorites = Set(photoIDs)
        PHAsset.fetchAssets(withLocalIdentifiers: photoIDs, options: nil).enumerateObjects { asset, _, _ in
            if !asset.isFavorite { favorites.remove(asset.localIdentifier) }
        }
        return items.filter { item in
            if case let .photo(id, _) = item.source { return !favorites.contains(id) }
            return false
        }
    }

    /// The size of the copies of these items only.
    func bytes(of items: [ArchiveItem]) -> Int64 {
        items.reduce(0) { $0 + (copies[$1.id]?.bytes ?? 0) }
    }
}

/// Removes originals from Apple Photos after a verified archive. Every copy is read back in full and
/// compared with its original first, and checked once more at the moment of deleting. Then the usual
/// sign-off and Apple's own confirmation. Favorites are never removed.
struct ArchivedRemovalView: View {
    let done: ArchiveCompletion
    @ObservedObject var model: DashboardModel
    @State private var agreed = false
    @State private var working = false
    @State private var message: String?
    @State private var result: RemovedResult?
    @State private var proofs: [ArchiveProof] = []
    @State private var staying: [Staying] = []
    @State private var checking = true
    @State private var checked = 0
    @State private var total = 0
    @State private var checkedAt = Date()
    @State private var round = 0
    @State private var wifi = ArchiveWiFi()
    @Environment(\.dismiss) private var dismiss

    private struct Staying: Identifiable {
        let id: String
        let name: String
        let reason: String
    }

    private var bytes: Int64 { proofs.reduce(0) { $0 + $1.record.bytes } }

    var body: some View {
        List {
            Section {
                Text("\(done.count) \(done.count == 1 ? "item was" : "items were") copied to \(done.place) and checked against the originals.")
                if checking {
                    ProgressView(value: Double(checked), total: Double(max(total, 1))) {
                        Text("Checking every copy again: \(checked) of \(total)")
                    }
                    .accessibilityIdentifier("archive-recheck")
                    Text("Each copy is read back in full and compared with its original. Keep this open.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if !proofs.isEmpty {
                    Label("\(proofs.count) \(proofs.count == 1 ? "copy is an exact match" : "copies are exact matches")", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(Brand.safe)
                        .accessibilityIdentifier("archive-recheck-ok")
                } else {
                    Text("Nothing can be deleted right now. Your originals stay on this iPhone.")
                }
                if !checking, total < done.photoIDs.count {
                    Text("Favorites stay on your iPhone.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !checking, !staying.isEmpty {
                Section("Staying on this iPhone") {
                    ForEach(staying) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                            Text(item.reason).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Button("Check again") {
                        message = nil
                        round += 1
                    }
                        .disabled(working)
                        .accessibilityIdentifier("archive-recheck-retry")
                }
            }
        }
        .navigationTitle("Free up space")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Not now") { dismiss() }.disabled(working) }
        }
        .safeAreaInset(edge: .bottom) {
            if !checking, !proofs.isEmpty {
                RemovalBar(count: proofs.count, bytes: bytes,
                           fullText: "I authorize TidyAway to delete \(proofs.count) selected items from Apple Photos. If iCloud Photos is on, these items will also be deleted from iCloud Photos and synced devices. Apple normally keeps deleted items in Recently Deleted for up to 30 days unless they're permanently deleted sooner. A verified full-resolution copy remains in \(done.place), last checked \(checkedAt.formatted(date: .omitted, time: .shortened)). This leaves one full-resolution copy. If that copy is lost, you could lose these items permanently.",
                           working: working, message: message, agreed: $agreed, delete: remove)
            } else if let message {
                Text(message).font(.subheadline).foregroundStyle(Brand.caution)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
                    .accessibilityIdentifier("removal-message")
            }
        }
        .interactiveDismissDisabled(working)
        .sheet(item: $result, onDismiss: { dismiss() }) { RescueResultView(result: $0) }
        .task(id: round) { await check() }
    }

    /// Reads every copy and every original in full. Only exact matches may be deleted.
    private func check() async {
        let candidates = done.removable
        checking = true
        agreed = false
        proofs = []
        staying = []
        checked = 0
        total = candidates.count
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        if done.copies.values.contains(where: \.viaHomeServer) {
            // The Wi-Fi check needs a moment to learn the connection.
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        var exact: [ArchiveProof] = []
        var kept: [Staying] = []
        for item in candidates {
            guard !Task.isCancelled, case let .photo(id, _) = item.source else { break }
            do {
                exact.append(try await ArchiveProver.prove(photoID: id, record: done.copies[item.id], wifi: wifi))
            } catch {
                kept.append(Staying(id: item.id, name: item.name, reason: error.localizedDescription))
            }
            checked += 1
        }
        guard !Task.isCancelled else { return }
        try? InventoryStore.openDefault().log("Checked \(candidates.count) archive copies in full before removal: \(exact.count) exact, \(kept.count) kept on this iPhone.")
        proofs = exact
        staying = kept
        checkedAt = Date()
        checking = false
    }

    private func remove() {
        let approved = proofs
        let approvedBytes = bytes
        guard agreed, !working, !checking, !approved.isEmpty else { return }
        working = true
        message = nil
        Task {
            // One last look at every copy and original. If anything changed, nothing is removed.
            for proof in approved {
                do {
                    try await ArchiveProver.confirm(proof, wifi: wifi)
                } catch {
                    try? InventoryStore.openDefault().log("Removal after archiving stopped: a copy or original couldn't be confirmed. Nothing was removed.")
                    message = "Something changed or couldn't be reached, so nothing was removed. All copies were checked again."
                    working = false
                    agreed = false
                    round += 1
                    return
                }
            }
            let outcome = await model.removeItems(approved.map(\.photoID), bytes: approvedBytes, from: "items archived to \(done.place)")
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
