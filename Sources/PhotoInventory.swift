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
        didSet { rescue = snapshot.map(RescueSummary.init) }
    }
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

    init() {
        do {
            store = try InventoryStore.openDefault()
            if authorization == .authorized || authorization == .limited {
                snapshot = try store?.load()
                // didSet doesn't run during init, so fill the rows here.
                rescue = snapshot.map(RescueSummary.init)
            }
            activity = try store?.activity() ?? []
        } catch { errorMessage = "Could not open local inventory: \(error.localizedDescription)" }
        if authorization == .authorized || authorization == .limited { startObserving() }
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
                if self.snapshot != nil { self.libraryChanged = true }
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
        guard !isScanning else { return .blocked("Wait for the scan to finish, then try again.") }
        let ids = plans.flatMap(\.removeIDs)
        guard !ids.isEmpty else { return .blocked("Select at least one extra copy.") }
        let operation = String(UUID().uuidString.prefix(8))
        try? store?.log("Authorized deleting \(ids.count) exact duplicate item(s) from \(plans.count) group(s) in Apple Photos. Disclosure v2. Operation \(operation).")
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
        guard !isScanning else { return .blocked("Wait for the scan to finish, then try again.") }
        guard !ids.isEmpty else { return .blocked("Select at least one item.") }
        let operation = String(UUID().uuidString.prefix(8))
        try? store?.log("Authorized deleting \(ids.count) item(s) from \(category) in Apple Photos. Disclosure v2. Operation \(operation).")
        defer { activity = (try? store?.activity()) ?? [] }
        return await delete(ids, bytes: bytes, operation: operation)
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
            if let current = snapshot {
                let updated = current.removing(Set(ids))
                snapshot = updated
                try? store?.save(updated)
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
            let records = try await scanner.scan { [weak self] done, count in
                await self?.setProgress(done, count)
            }
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
            do {
                if let store {
                    try store.save(result)
                } else {
                    duplicateScanStatus = "Scan complete. Results are available for this session only."
                }
            } catch {
                duplicateScanStatus = "Scan complete. Results couldn’t be saved and are available for this session only."
            }
            activity = (try? store?.activity()) ?? []
        } catch is CancellationError {
            if errorMessage == nil { duplicateScanStatus = "Scan stopped. No new results were saved." }
            try? store?.log("Scan cancelled; incomplete results were not saved.")
            activity = (try? store?.activity()) ?? []
        } catch {
            errorMessage = error.localizedDescription
            try? store?.log("Scan failed: \(error.localizedDescription)")
            activity = (try? store?.activity()) ?? []
        }
    }

    private func setProgress(_ done: Int, _ count: Int) { completed = done; total = count }

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

