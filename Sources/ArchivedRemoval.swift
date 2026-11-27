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
        items.reduce(0) { $0 + (copies[$1.id]?.totalBytes ?? 0) }
    }
}

/// Removes originals from Apple Photos after a verified archive. Every copy must still be on its
/// destination at exactly the size of its original, and is checked once more at the moment of deleting. Then the usual
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
    /// How much of the originals the check has read again so far, so a large video never looks stuck.
    @State private var reading = ProofProgress()
    @State private var readBytes: Int64 = 0
    /// How much of the copies on a drive, folder or home server has been read back so far (1.0.2, A3).
    @State private var readingCopies = ProofProgress()
    @State private var copyBytes: Int64 = 0
    /// Bringing one copy back and checking it against its original. Removal waits for it.
    @State private var test = RestoreTest.notYet
    /// What removal is doing right now, with a count, so a long step never looks stuck.
    @State private var phase: String?
    @State private var phaseDone = 0
    @State private var phaseTotal = 0
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    enum RestoreTest: Equatable {
        case notYet, running, passed(String), failed(String)
        /// Two came back: the smallest copy, and the smallest Live Photo or edited photo.
        case passedTwo(String, String)
    }

    private var tested: Bool {
        switch test {
        case .passed, .passedTwo: true
        default: false
        }
    }

    private struct Staying: Identifiable {
        let id: String
        let name: String
        let reason: String
    }

    private var bytes: Int64 { proofs.reduce(0) { $0 + $1.record.totalBytes } }

    /// Copies on a drive, folder or home server are read back in full before removal; cloud copies
    /// are matched by the service's checksum.
    private var readsCopiesBack: Bool {
        done.copies.values.contains { $0.cloud == nil && $0.driveFileID == nil }
    }

    var body: some View {
        List {
            Section {
                Text("\(done.count) \(done.count == 1 ? "item was" : "items were") copied to \(done.place) and checked against the originals.")
                if checking {
                    ProgressView(value: Double(checked), total: Double(max(total, 1))) {
                        Text("Checking every copy: \(checked) of \(total)")
                    }
                    .accessibilityIdentifier("archive-recheck")
                    if readBytes > 0 {
                        Text("Read \(readBytes.fileSize) of your originals so far.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("archive-recheck-read")
                    }
                    if copyBytes > 0 {
                        Text("Read back \(copyBytes.fileSize) of the copies on \(done.place) so far.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .accessibilityIdentifier("archive-recheck-copies")
                    }
                    Text(readsCopiesBack
                         ? "Each copy must still be there, the same size as its original to the byte. Copies on a drive or server are read back in full the first time. Keep this open."
                         : "Each copy must still be there, the same size as its original to the byte. Keep this open.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if let phase {
                    ProgressView(value: Double(phaseDone), total: Double(max(phaseTotal, 1))) {
                        Text(phaseTotal > 0 ? "\(phase): \(phaseDone) of \(phaseTotal)" : phase)
                    }
                    .accessibilityIdentifier("removal-phase")
                    Text("Keep TidyAway open. This can take a few minutes for a large set.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if !proofs.isEmpty {
                    checklist
                } else {
                    Text("Nothing can be deleted right now. Your originals stay on this \(Device.name).")
                }
                if !checking, total < done.photoIDs.count {
                    Text("Favorites stay on your \(Device.name).").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if !checking, !staying.isEmpty {
                Section("Staying on this \(Device.name)") {
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
            if !checking, !proofs.isEmpty, !tested {
                Button(test == .running ? "Bringing one back…" : "Test bringing one back") { Task { await bringOneBack() } }
                    .buttonStyle(ArchiveButtonStyle())
                    .disabled(test == .running)
                    .padding(16)
                    .background(.regularMaterial)
                    .accessibilityIdentifier("archive-restore-test")
            } else if !checking, !proofs.isEmpty {
                RemovalBar(count: proofs.count, bytes: bytes,
                           fullText: "I opened \(done.place) and I can see these copies. I authorize TidyAway to delete \(proofs.count) selected items from Apple Photos. If iCloud Photos is on, these items will also be deleted from iCloud Photos and synced devices. Apple normally keeps deleted items in Recently Deleted for up to 30 days unless they're permanently deleted sooner. A verified full-resolution copy remains in \(done.place), last checked \(checkedAt.formatted(date: .omitted, time: .shortened)). This leaves one full-resolution copy. If that copy is lost, you could lose these items permanently.",
                           working: working, message: message, agreed: $agreed, delete: remove)
            } else if let message {
                Text(message).font(.subheadline).foregroundStyle(Brand.caution)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(.regularMaterial)
                    .accessibilityIdentifier("removal-message")
            }
        }
        .interactiveDismissDisabled(working)
        .sheet(item: $result, onDismiss: { dismiss() }) {
            RescueResultView(result: $0, note: "Look at your copies in \(done.place) before you empty Recently Deleted. Until then, the originals can still be recovered there for 30 days.")
        }
        .task(id: round) { await check() }
    }

    /// Checks every copy, a few at a time. Only confirmed copies may have their originals deleted.
    private func check() async {
        let candidates = done.removable
        checking = true
        agreed = false
        test = .notYet
        proofs = []
        staying = []
        checked = 0
        total = candidates.count
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = false }
        let progress = reading
        progress.reset()
        readBytes = 0
        let copiesRead = readingCopies
        copiesRead.reset()
        copyBytes = 0
        let watch = Task {
            while !Task.isCancelled {
                readBytes = progress.bytes
                copyBytes = copiesRead.bytes
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        defer { watch.cancel() }
        if done.copies.values.contains(where: \.viaHomeServer) {
            // The Wi-Fi check needs a moment to learn the connection.
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        var exact: [ArchiveProof] = []
        var kept: [Staying] = []
        let network = wifi
        let copies = done.copies
        await withTaskGroup(of: (ArchiveItem, Result<ArchiveProof, Error>).self) { group in
            var waiting = candidates[...]
            var running = 0
            while true {
                while running < 6, !Task.isCancelled, let item = waiting.popFirst() {
                    guard case let .photo(id, _) = item.source else { continue }
                    running += 1
                    let record = copies[item.id]
                    group.addTask {
                        (item, await Result(awaiting: {
                            let proof = try await ArchiveProver.prove(photoID: id, record: record, wifi: network, progress: progress,
                                                                      copies: copiesRead)
                            // A confirmed copy the person can't see (OneDrive's app folder in work and school
                            // accounts) is not enough: its original stays.
                            // For a Live Photo or edited photo, that goes for every one of its files.
                            guard await CopyVisibility.canAllBeSeen(proof.record) else { throw HiddenCopy() }
                            // A Live Photo or edited photo may go only if Photos on this iPhone says it
                            // can build one item out of its files again.
                            guard !proof.record.hasParts || ArchiveRestore.photosCanRebuild(proof.record.partTypes) else {
                                throw CannotRebuild()
                            }
                            return proof
                        }))
                    }
                }
                guard let next = await group.next() else { break }
                let (item, result) = next
                running -= 1
                switch result {
                case .success(let proof): exact.append(proof)
                case .failure(let error): kept.append(Staying(id: item.id, name: item.name, reason: error.localizedDescription))
                }
                checked += 1
            }
        }
        guard !Task.isCancelled else { return }
        // A copy that is confirmed but kept where the person can't see it (OneDrive's hidden app folder
        // in work and school accounts) is not enough: its original stays.
        try? InventoryStore.openDefault().log("Checked \(candidates.count) archive copies before removal: \(exact.count) confirmed, \(kept.count) kept on this \(Device.name).")
        proofs = exact
        staying = kept
        checkedAt = Date()
        checking = false
    }

    /// The four checks, ticked as they pass.
    @ViewBuilder
    private var checklist: some View {
        check(true, "Copied, byte for byte",
              "\(proofs.count) of \(total): each copy is there and the same size as its original")
        VStack(alignment: .leading, spacing: 4) {
            check(true, "Where they are", done.place)
            if let link = openLink {
                Button("Open \(done.place) ↗") { openURL(link) }
                    .font(.footnote.weight(.semibold))
                    .padding(.leading, 34)
                    .accessibilityIdentifier("archive-open-place")
            }
        }
        switch test {
        case .passed(let name):
            check(true, "One brought back and checked", "\(name) matched its original exactly")
        case let .passedTwo(first, second):
            check(true, "Two brought back and checked", "\(first) and \(second) matched their originals exactly")
        case .failed(let reason):
            check(false, "Bring one back to test", reason, problem: true)
        default:
            check(false, "Bring one back to test", "TidyAway downloads the smallest copy and checks it against its original")
        }
        check(tested, "Your OK", "You confirm you can see the copies, then Apple asks too")
    }

    private func check(_ done: Bool, _ title: String, _ detail: String, problem: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : problem ? "exclamationmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(done ? Brand.safe : problem ? Brand.caution : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? "Done" : "Not yet")
    }

    /// The service's page for the place the copies went, when it has one.
    private var openLink: URL? {
        guard let record = proofs.first?.record else { return nil }
        if record.cloud == .dropbox { return URL(string: "https://www.dropbox.com/home/Apps/TidyAway") }
        if record.cloud == .oneDrive { return URL(string: "https://onedrive.live.com/") }
        if let id = record.driveFileID { return URL(string: "https://drive.google.com/file/d/\(id)/view") }
        return nil
    }

    /// Downloads the smallest confirmed copy and compares it with its original's fingerprint. When the
    /// set holds Live Photos or edited photos, the smallest of those is brought back too, every file of it.
    private func bringOneBack() async {
        let chosen = RestoreTestChoice.records(from: proofs.map(\.record))
        guard let first = chosen.first else { return }
        test = .running
        do {
            for record in chosen {
                let urls = try await ArchiveRestore.verifiedCopies(record, wifi: wifi)
                for url in urls { try? FileManager.default.removeItem(at: url) }
                guard urls.count == record.files.count else { throw ArchiveError.verification }
            }
            if chosen.count > 1 {
                test = .passedTwo(first.name, chosen[1].name)
                try? InventoryStore.openDefault().log("Two test restores from \(done.place) matched their originals.")
            } else {
                test = .passed(first.name)
                try? InventoryStore.openDefault().log("Test restore from \(done.place) matched its original.")
            }
        } catch {
            test = .failed("Couldn't bring it back: \(error.localizedDescription) Your originals stay until this works.")
        }
    }

    private func show(_ text: String, total: Int) {
        phase = text
        phaseDone = 0
        phaseTotal = total
    }

    private func remove() {
        let approved = proofs
        let approvedBytes = bytes
        guard agreed, tested, !working, !checking, !approved.isEmpty else { return }
        working = true
        message = nil
        Task {
            // One last look at every copy and original, six at a time. If anything changed, nothing is removed.
            show("Checking each copy once more", total: approved.count)
            let network = wifi
            var failed = false
            await withTaskGroup(of: Bool.self) { group in
                var waiting = approved[...]
                var running = 0
                while true {
                    while running < 6, !failed, let proof = waiting.popFirst() {
                        running += 1
                        group.addTask { (try? await ArchiveProver.confirm(proof, wifi: network)) != nil }
                    }
                    guard let ok = await group.next() else { break }
                    running -= 1
                    if !ok { failed = true }
                    phaseDone += 1
                }
            }
            if failed {
                phase = nil
                try? InventoryStore.openDefault().log("Removal after archiving stopped: a copy or original couldn't be confirmed. Nothing was removed.")
                message = "Something changed or couldn't be reached, so nothing was removed. All copies were checked again."
                working = false
                agreed = false
                round += 1
                return
            }
            // Small pictures for Get back, kept on this iPhone before the originals go.
            show("Saving small pictures for Get back", total: approved.count)
            await ArchiveThumbnails.remember(approved.map(\.photoID)) { done, _ in
                await MainActor.run { phaseDone = done }
            }
            show("Waiting for Apple to ask you to confirm", total: 0)
            let outcome = await model.removeItems(approved.map(\.photoID), bytes: approvedBytes, from: "items archived to \(done.place)")
            phase = nil
            working = false
            agreed = false
            switch outcome {
            case let .removed(count, bytes): result = RemovedResult(count: count, bytes: bytes)
                try? InventoryStore.openDefault().log("Removed \(count) archived items from Photos after a test restore from \(done.place) matched its original.")
            case .cancelled: message = "Cancelled. Nothing was removed."
            case .sample: message = "Sample data. Nothing was removed."
            case .blocked(let reason): message = reason
            }
        }
    }
}

/// Which copies the test restore brings back before anything may be deleted.
enum RestoreTestChoice {
    /// The smallest copy, as always. If that one is a single file and the set also holds Live Photos or
    /// edited photos, the smallest of those as well, so a copy made of several files is always tested
    /// when there is one.
    static func records(from records: [ArchivedRecord]) -> [ArchivedRecord] {
        guard let smallest = records.min(by: { $0.totalBytes < $1.totalBytes }) else { return [] }
        if smallest.hasParts { return [smallest] }
        guard let several = records.filter(\.hasParts).min(by: { $0.totalBytes < $1.totalBytes }) else { return [smallest] }
        return [smallest, several]
    }
}

/// A Live Photo or edited photo whose files are all confirmed, but Photos won't build one item from them.
struct CannotRebuild: LocalizedError {
    var errorDescription: String? {
        "Photos on this \(Device.name) can't rebuild this Live Photo or edited photo from its copies, so it stays."
    }
}

/// A copy that is confirmed but kept where the person can't see it.
struct HiddenCopy: LocalizedError {
    var errorDescription: String? {
        "Its copy is in OneDrive's app folder (Apps › TidyAway), which OneDrive doesn't always show. Get back can still bring it back. New copies go to My files › TidyAway, where you can see them."
    }
}
