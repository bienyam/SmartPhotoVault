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
            categorySummaries = snapshot.flatMap { $0.recordsCategories ? $0.cleanSummaries() : nil }
        }
    }
    /// Clean tab categories, worked out once per scan rather than on every redraw.
    @Published private(set) var categorySummaries: [CleanCategorySummary]?
    @Published var activity: [ActivityEntry] = []
    @Published var errorMessage: String?
    @Published private(set) var duplicateScanStatus: String?
    @Published var completed = 0
    @Published var total = 0
    @Published var isDemo = false
    private var store: InventoryStore?
    private let scanner = DuplicateScanner()
    private var scanTask: Task<Void, Never>?
    private var changeObserver: LibraryChangeObserver?
    private var ownChangePending = false

    init() {
        do {
            store = try InventoryStore.openDefault()
            if authorization == .authorized {
                snapshot = try store?.load()
                // didSet doesn't run during init, so fill the categories here.
                categorySummaries = snapshot.flatMap { $0.recordsCategories ? $0.cleanSummaries() : nil }
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
                self.cancel()
                self.snapshot = nil
                self.inventory = nil
                if self.ownChangePending {
                    self.ownChangePending = false
                    self.duplicateScanStatus = "Duplicates removed. Scan again to refresh the results."
                    return
                }
                self.duplicateScanStatus = nil
                self.errorMessage = "Your Photos library changed. Run a new scan to refresh the results."
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
    /// Every item is re-read and compared with the scan first. Apple Photos then shows its own
    /// confirmation, and deleted items go to Recently Deleted.
    func removeDuplicates(_ plan: DuplicateRemovalPlan) async -> DuplicateRemovalOutcome {
        if isDemo { return .sample }
        guard !isScanning else { return .blocked("Wait for the scan to finish, then try again.") }
        let operation = String(UUID().uuidString.prefix(8))
        let count = plan.removeIDs.count
        try? store?.log("Authorized deleting \(count) exact duplicate item(s) from Apple Photos. Operation \(operation).")
        defer { activity = (try? store?.activity()) ?? [] }
        func blocked(_ reason: String) -> DuplicateRemovalOutcome {
            try? store?.log("Operation \(operation) blocked. Nothing was removed.")
            return .blocked(reason)
        }
        do {
            guard try await scanner.fingerprint(for: plan.keepID) == plan.fingerprint else {
                return blocked("The copy to keep could not be verified, so nothing was removed. Scan again.")
            }
            for id in plan.removeIDs {
                guard try await scanner.fingerprint(for: id) == plan.fingerprint else {
                    return blocked("An item changed since the scan, so nothing was removed. Scan again.")
                }
            }
            let targets = PHAsset.fetchAssets(withLocalIdentifiers: plan.removeIDs, options: nil)
            var includesFavorite = false
            targets.enumerateObjects { asset, _, _ in if asset.isFavorite { includesFavorite = true } }
            guard targets.count == count, !includesFavorite else {
                return blocked("An item changed since the scan, so nothing was removed. Scan again.")
            }
            ownChangePending = true
            try await PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(targets)
            }
            try? store?.log("Operation \(operation) finished: \(count) item(s) moved to Recently Deleted.")
            return .removed(count: count, bytes: plan.removeBytes)
        } catch {
            ownChangePending = false
            if (error as NSError).code == 3072 {
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
        snapshot = nil
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
        snapshot = nil
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
        // Keep a completed inventory when access is unchanged. In particular,
        // closing the initial permission dialog must not erase a just-finished scan.
        if previous != authorization || (authorization == .limited && !isScanning) {
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

