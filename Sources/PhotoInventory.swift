import Photos
import Foundation
import Combine

struct PhotoInventory: Equatable {
    var photos = 0
    var videos = 0
    var favorites = 0
    var screenshots: Int?
    var total: Int { photos + videos }
}

enum PhotoLibraryService {
    static func inventory() async -> PhotoInventory {
        await Task.detached(priority: .userInitiated) {
            let assets = PHAsset.fetchAssets(with: nil)
            var result = PhotoInventory(screenshots: 0)
            assets.enumerateObjects { asset, _, _ in
                switch asset.mediaType {
                case .image: result.photos += 1
                case .video: result.videos += 1
                default: break
                }
                if asset.isFavorite { result.favorites += 1 }
                if asset.mediaSubtypes.contains(.photoScreenshot) { result.screenshots? += 1 }
            }
            return result
        }.value
    }
}

@MainActor
final class DashboardModel: ObservableObject {
    @Published var inventory: PhotoInventory?
    @Published var authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var isScanning = false
    @Published var snapshot: ScanSnapshot? {
        didSet {
            snapshotVersion &+= 1
            // Saved results arrive with their rows already worked out away from the main thread.
            if !adoptingSaved { rescue = snapshot.map(RescueSummary.init) }
        }
    }
    /// True while the saved results are read at launch, before the Free up rows can show them.
    @Published private(set) var isLoadingSaved = false
    /// What the top of the Free up tab shows when there are no results on screen.
    enum FreeUpStart: Equatable { case scanning, loadingSaved, empty, results }
    /// The empty "Free up space" state only once the saved results are known to be missing.
    var freeUpStart: FreeUpStart {
        Self.freeUpStart(scanning: isScanning, loadingSaved: isLoadingSaved, hasResults: rescue != nil)
    }
    nonisolated static func freeUpStart(scanning: Bool, loadingSaved: Bool, hasResults: Bool) -> FreeUpStart {
        if scanning { return .scanning }
        if hasResults { return .results }
        return loadingSaved ? .loadingSaved : .empty
    }
    /// The launch-time read of the saved results. Tests wait on it.
    private(set) var savedLoad: Task<Void, Never>?
    /// The Free up tab's rows, worked out once per scan rather than on every redraw.
    @Published private(set) var rescue: RescueSummary?
    @Published var activity: [ActivityEntry] = []
    @Published var errorMessage: String?
    @Published private(set) var duplicateScanStatus: String?
    @Published var completed = 0
    @Published var total = 0
    @Published var isDemo = false
    /// True when Photos changed outside TidyAway since the last scan. Results stay usable;
    /// every removal re-checks its items, and the user can refresh when they like.
    @Published private(set) var libraryChanged = false
    private var store: InventoryStore?
    private let scanner = DuplicateScanner()
    private var scanTask: Task<Void, Never>?
    private var changeObserver: LibraryChangeObserver?
    /// Our own deletions also trigger Photos' change notice; those are already reflected in the results.
    private var ownChanges = 0
    /// Items deleted while a check is still running, left out of its final results.
    private var deletedDuringScan: Set<String> = []
    private var partialDate = Date()
    /// Counts every change to `snapshot`, so a slow launch read never replaces newer results.
    private var snapshotVersion = 0
    private var adoptingSaved = false
    /// Reads and writes of the saved results run here, one at a time and in the order asked,
    /// so a later save always lands after an earlier one and the main thread never waits on them.
    private let storeQueue = DispatchQueue(label: "com.bienyam.SmartPhotoVault.saved-scan", qos: .userInitiated)

    convenience init() {
        self.init(opening: { try InventoryStore.openDefault() })
    }

    /// `open` supplies the inventory; tests pass their own, or none.
    init(opening open: () throws -> InventoryStore?) {
        do {
            store = try open()
            activity = try store?.activity() ?? []
        } catch { errorMessage = "Could not open local inventory: \(error.localizedDescription)" }
        if authorization == .authorized || authorization == .limited {
            loadSaved()
            startObserving()
        }
    }

    private struct SavedScan {
        let snapshot: ScanSnapshot
        let rescue: RescueSummary
    }

    /// Decodes the saved results and works out the Free up rows off the main thread, so a large
    /// library doesn't hold up the first frame. The Free up tab shows its usual empty state meanwhile.
    private func loadSaved() {
        guard let store else { return }
        isLoadingSaved = true
        let version = snapshotVersion
        let queue = storeQueue
        savedLoad = Task {
            let result = await withCheckedContinuation { (continuation: CheckedContinuation<Result<SavedScan?, Error>, Never>) in
                queue.async {
                    continuation.resume(returning: Result(catching: {
                        try store.load().map { SavedScan(snapshot: $0, rescue: RescueSummary(snapshot: $0)) }
                    }))
                }
            }
            self.finishLoading(result, startedAt: version)
        }
    }

    private func finishLoading(_ result: Result<SavedScan?, Error>, startedAt version: Int) {
        isLoadingSaved = false
        // A scan, sample data, a delete or an access change since the read began is newer: keep it.
        guard version == snapshotVersion else { return }
        switch result {
        case .success(let saved?):
            adoptingSaved = true
            snapshot = saved.snapshot
            adoptingSaved = false
            // A check already running shows its own early results; these are its fallback if stopped.
            if !isScanning { rescue = saved.rescue }
        case .success(nil):
            libraryChanged = false
        case .failure(let error):
            libraryChanged = false
            errorMessage = "Could not open local inventory: \(error.localizedDescription)"
        }
    }

    /// Saves the results off the main thread, after any save asked for earlier.
    private func persist(_ snapshot: ScanSnapshot, ifFailed failed: (@MainActor () -> Void)? = nil) {
        guard let store else { return }
        storeQueue.async {
            let saved = (try? store.save(snapshot)) != nil
            Task { @MainActor in
                if !saved { failed?() }
                // The save writes its own activity line.
                if let latest = try? store.activity() { self.activity = latest }
            }
        }
    }

    private func startObserving() {
        guard changeObserver == nil else { return }
        changeObserver = LibraryChangeObserver { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isDemo else { return }
                if self.ownChanges > 0 {
                    self.ownChanges -= 1
                    return
                }
                // Keep the results: wiping them forced a full rescan after every edit in Photos.
                if self.snapshot != nil || self.isLoadingSaved { self.libraryChanged = true }
            }
        }
    }

    func startDuplicateScan() {
        guard !isScanning else { return }
        isScanning = true
        duplicateScanStatus = nil
        scanTask = Task { await scanDuplicates() }
    }

    func cancel() { scanTask?.cancel() }

    /// Other screens write to the activity log directly, so the Ledger reloads it when shown.
    func reloadActivity() {
        if let latest = try? store?.activity() { activity = latest }
    }

    /// Removes the extra copies in one exact-duplicate group after the user has signed off.
    func removeDuplicates(_ plan: DuplicateRemovalPlan) async -> DuplicateRemovalOutcome {
        await removeDuplicates([plan])
    }

    /// Removes extra copies across any number of exact-duplicate groups under one sign-off and one
    /// Apple confirmation. Every copy to keep and every copy to remove is re-read and compared with
    /// the scan first; if anything changed, nothing is removed. Deleted items go to Recently Deleted.
    func removeDuplicates(_ plans: [DuplicateRemovalPlan]) async -> DuplicateRemovalOutcome {
        if isDemo { return .sample }
        let ids = plans.flatMap(\.removeIDs)
        guard !ids.isEmpty else { return .blocked("Select at least one extra copy.") }
        let operation = String(UUID().uuidString.prefix(8))
        // The sign-off must be on record before anything is deleted, as with archiving.
        guard Self.recordApproval("Authorized deleting \(ids.count) exact duplicate item(s) from \(plans.count) group(s) in Apple Photos. Disclosure v2. Operation \(operation).", store?.log) else {
            return .blocked(Self.approvalNotSaved)
        }
        defer { activity = (try? store?.activity()) ?? [] }
        do {
            for plan in plans {
                guard try await scanner.fingerprint(for: plan.keepID) == plan.fingerprint else {
                    return blocked(operation, "A copy to keep could not be checked, so nothing was removed. Refresh and try again.")
                }
                for id in plan.removeIDs {
                    guard try await scanner.fingerprint(for: id) == plan.fingerprint else {
                        return blocked(operation, "An item changed since the scan, so nothing was removed. Refresh and try again.")
                    }
                }
            }
        } catch {
            return blocked(operation, "An item couldn't be checked, so nothing was removed. Refresh and try again.")
        }
        return await delete(ids, bytes: plans.reduce(0) { $0 + $1.removeBytes }, operation: operation)
    }

    /// Deletes items the user picked from a Clean category, after they signed off.
    /// These are not duplicates, so every item is re-checked first: still present, still not a favorite.
    /// Apple Photos then shows its own confirmation, and deleted items go to Recently Deleted.
    func removeItems(_ ids: [String], bytes: Int64, from category: String) async -> DuplicateRemovalOutcome {
        if isDemo { return .sample }
        guard !ids.isEmpty else { return .blocked("Select at least one item.") }
        let operation = String(UUID().uuidString.prefix(8))
        guard Self.recordApproval("Authorized deleting \(ids.count) item(s) from \(category) in Apple Photos. Disclosure v2. Operation \(operation).", store?.log) else {
            return .blocked(Self.approvalNotSaved)
        }
        defer { activity = (try? store?.activity()) ?? [] }
        return await delete(ids, bytes: bytes, operation: operation)
    }

    /// Same words the archive screen uses when it can't record a sign-off.
    static let approvalNotSaved = "The app could not save your authorization. Try again."

    /// Writes the user's sign-off to the activity log. False when it couldn't be written,
    /// including when the log isn't open; then nothing may be removed.
    nonisolated static func recordApproval(_ message: String, _ log: ((String) throws -> Void)?) -> Bool {
        guard let log else { return false }
        do {
            try log(message)
            return true
        } catch {
            return false
        }
    }

    private func blocked(_ operation: String, _ reason: String) -> DuplicateRemovalOutcome {
        try? store?.log("Operation \(operation) blocked. Nothing was removed.")
        return .blocked(reason)
    }

    /// The one place that asks Photos to delete. Re-checks presence and favorites, then drops the
    /// deleted items from the saved results so the lists stay usable without a rescan.
    private func delete(_ ids: [String], bytes: Int64, operation: String) async -> DuplicateRemovalOutcome {
        let targets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
        var includesFavorite = false
        targets.enumerateObjects { asset, _, _ in if asset.isFavorite { includesFavorite = true } }
        guard targets.count == ids.count, !includesFavorite else {
            return blocked(operation, "An item changed since the scan, so nothing was removed. Refresh and try again.")
        }
        do {
            ownChanges += 1
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(targets)
            }
            try? store?.log("Operation \(operation) finished: \(ids.count) item(s) moved to Recently Deleted.")
            RecentRemovals.add(bytes)
            RatingPrompt.noteCompletion()
            if isScanning {
                // People can act on early results; the rest of the check keeps going.
                deletedDuringScan.formUnion(ids)
                if let rescue { self.rescue = rescue.removing(Set(ids)) }
            } else if let current = snapshot {
                let updated = current.removing(Set(ids))
                snapshot = updated
                persist(updated)
            }
            return .removed(count: ids.count, bytes: bytes)
        } catch {
            ownChanges = max(0, ownChanges - 1)
            if (error as NSError).code == PHPhotosError.userCancelled.rawValue {
                try? store?.log("Operation \(operation) cancelled at Apple's confirmation. Nothing was removed.")
                return .cancelled
            }
            try? store?.log("Operation \(operation) failed. Nothing was removed.")
            return .blocked("Apple Photos did not remove the items: \(error.localizedDescription)")
        }
    }

    func startMetadataScan() {
        guard !isScanning else { return }
        isScanning = true
        scanTask = Task { await scan() }
    }

    private func scanDuplicates() async {
        isScanning = true
        isDemo = false
        inventory = nil
        completed = 0
        total = 0
        errorMessage = nil
        defer { isScanning = false; scanTask = nil }
        do {
            try Task.checkCancellation()
            authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if authorization == .notDetermined {
                authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            }
            guard authorization == .authorized || authorization == .limited else {
                errorMessage = "Scan couldn’t start because Photos access is unavailable."
                try? store?.log("Scan not started: photo access unavailable.")
                activity = (try? store?.activity()) ?? []
                return
            }
            startObserving()
            try Task.checkCancellation()
            try? store?.log("Local duplicate scan started.")
            deletedDuringScan = []
            partialDate = Date()
            let found = try await scanner.scanProgressively(progress: { [weak self] done, count in
                await self?.setProgress(done, count)
            }, partial: { [weak self] records in
                await self?.showPartial(records)
            })
            let records = found.filter { !deletedDuringScan.contains($0.id) }
            deletedDuringScan = []
            try Task.checkCancellation()
            let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard current == authorization else {
                throw NSError(domain: "PhotoAccess", code: 1, userInfo: [NSLocalizedDescriptionKey: "Photo access changed during the scan. Please scan again."])
            }
            let result = ScanSnapshot(date: Date(), limitedAccess: authorization == .limited, includedCloudDownloads: false, assets: records,
                                      albums: await scanner.lastAlbums)
            snapshot = result
            libraryChanged = false
            inventory = counts(for: records)
            duplicateScanStatus = "Scan complete."
            if store != nil {
                persist(result) { [weak self] in
                    guard let self, !self.isScanning else { return }
                    self.duplicateScanStatus = "Scan complete. Results couldn’t be saved and are available for this session only."
                }
            } else {
                duplicateScanStatus = "Scan complete. Results are available for this session only."
            }
            activity = (try? store?.activity()) ?? []
        } catch is CancellationError {
            restoreAfterIncompleteScan()
            if errorMessage == nil { duplicateScanStatus = "Check stopped. Your earlier results are still here." }
            try? store?.log("Scan cancelled; incomplete results were not saved.")
            activity = (try? store?.activity()) ?? []
        } catch {
            restoreAfterIncompleteScan()
            errorMessage = error.localizedDescription
            try? store?.log("Scan failed: \(error.localizedDescription)")
            activity = (try? store?.activity()) ?? []
        }
    }

    /// A stopped or failed check falls back to the last complete one, minus anything deleted meanwhile.
    private func restoreAfterIncompleteScan() {
        if !deletedDuringScan.isEmpty, let current = snapshot {
            let updated = current.removing(deletedDuringScan)
            snapshot = updated
            persist(updated)
        } else {
            rescue = snapshot.map(RescueSummary.init)
        }
        deletedDuringScan = []
    }

    private func setProgress(_ done: Int, _ count: Int) { completed = done; total = count }

    /// Early results while the check continues, biggest items first.
    private func showPartial(_ records: [AssetRecord]) {
        guard isScanning else { return }
        let kept = records.filter { !deletedDuringScan.contains($0.id) }
        rescue = RescueSummary(snapshot: ScanSnapshot(date: partialDate, limitedAccess: authorization == .limited,
                                                      includedCloudDownloads: false, assets: kept))
    }

    func showDemo() {
        guard !isScanning else { return }
        isDemo = true
        duplicateScanStatus = nil
        errorMessage = nil
        snapshot = DemoLibrary.snapshot
        inventory = counts(for: DemoLibrary.snapshot.assets)
    }

    private func counts(for records: [AssetRecord]) -> PhotoInventory {
        let photos = records.filter { $0.mediaType == PHAssetMediaType.image.rawValue }
        return PhotoInventory(photos: photos.count,
                       videos: records.filter { $0.mediaType == PHAssetMediaType.video.rawValue }.count,
                       favorites: records.filter(\.favorite).count,
                       screenshots: photos.allSatisfy { $0.isScreenshot != nil } ? photos.filter { $0.isScreenshot == true }.count : nil)
    }

    private func scan() async {
        isDemo = false
        duplicateScanStatus = nil
        isScanning = true
        defer { isScanning = false; scanTask = nil }
        inventory = nil
        guard !Task.isCancelled else { return }
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if authorization == .notDetermined {
            authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard authorization == .authorized || authorization == .limited else { return }
        startObserving()
        let result = await PhotoLibraryService.inventory()
        guard !Task.isCancelled else { return }
        inventory = result
    }

    func refreshAuthorization() {
        let previous = authorization
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard !isDemo else { return }
        // Keep completed results when access is unchanged. In particular, returning from Apple's
        // delete confirmation or the permission dialog must not erase a just-finished scan.
        // Changes to a Limited selection arrive through the library change notice instead.
        if previous != authorization {
            inventory = nil
            if previous != .notDetermined && isScanning {
                errorMessage = "Photos access changed. Run a new scan with your current access."
                cancel()
            }
            duplicateScanStatus = nil
            snapshot = nil
            isDemo = false
        }
    }
}

private final class LibraryChangeObserver: NSObject, PHPhotoLibraryChangeObserver {
    let changed: () -> Void
    init(changed: @escaping () -> Void) {
        self.changed = changed
        super.init()
        PHPhotoLibrary.shared().register(self)
    }
    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }
    func photoLibraryDidChange(_ changeInstance: PHChange) { changed() }
}

