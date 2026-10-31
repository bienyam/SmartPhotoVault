import Photos
import Foundation
import Combine

struct PhotoInventory: Equatable {
    var photos = 0
    var videos = 0
    var favorites = 0
    var total: Int { photos + videos }
}

enum PhotoLibraryService {
    static func inventory() async -> PhotoInventory {
        await Task.detached(priority: .userInitiated) {
            let assets = PHAsset.fetchAssets(with: nil)
            var result = PhotoInventory()
            assets.enumerateObjects { asset, _, _ in
                switch asset.mediaType {
                case .image: result.photos += 1
                case .video: result.videos += 1
                default: break
                }
                if asset.isFavorite { result.favorites += 1 }
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
    @Published var snapshot: ScanSnapshot?
    @Published var activity: [ActivityEntry] = []
    @Published var errorMessage: String?
    @Published var completed = 0
    @Published var total = 0
    @Published var allowCloudDownloads = false
    @Published var isDemo = false
    private var store: InventoryStore?
    private let scanner = DuplicateScanner()
    private var scanTask: Task<Void, Never>?
    private var changeObserver: LibraryChangeObserver?

    init() {
        do {
            store = try InventoryStore.openDefault()
            if authorization == .authorized {
                snapshot = try store?.load()
            }
            activity = try store?.activity() ?? []
        } catch { errorMessage = "Could not open local inventory: \(error.localizedDescription)" }
        changeObserver = LibraryChangeObserver { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isDemo else { return }
                self.cancel()
                self.snapshot = nil
                self.inventory = nil
                self.errorMessage = "Your Photos library changed. Run a new scan to refresh the results."
            }
        }
    }

    func startDuplicateScan() {
        guard !isScanning else { return }
        scanTask = Task { await scanDuplicates() }
    }

    func cancel() { scanTask?.cancel() }

    private func scanDuplicates() async {
        guard store != nil else {
            errorMessage = "Local inventory storage is unavailable. Restart the app to try opening it again."
            return
        }
        isScanning = true
        isDemo = false
        completed = 0
        total = 0
        errorMessage = nil
        snapshot = nil
        defer { isScanning = false; scanTask = nil }
        do {
            authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            if authorization == .notDetermined {
                authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            }
            guard authorization == .authorized || authorization == .limited else {
                try store?.log("Scan not started: photo access unavailable.")
                activity = try store?.activity() ?? []
                return
            }
            try Task.checkCancellation()
            try store?.log("Duplicate scan started. Cloud downloads: \(allowCloudDownloads ? "enabled" : "disabled").")
            let downloads = allowCloudDownloads
            let records = try await scanner.scan(allowNetwork: downloads) { [weak self] done, count in
                await self?.setProgress(done, count)
            }
            try Task.checkCancellation()
            let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard current == authorization else {
                throw NSError(domain: "PhotoAccess", code: 1, userInfo: [NSLocalizedDescriptionKey: "Photo access changed during the scan. Please scan again."])
            }
            let result = ScanSnapshot(date: Date(), limitedAccess: authorization == .limited, includedCloudDownloads: downloads, assets: records)
            snapshot = result
            try store?.save(result)
            activity = try store?.activity() ?? []
        } catch is CancellationError {
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
        snapshot = DemoLibrary.snapshot
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        inventory = nil
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if authorization == .notDetermined {
            authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        guard authorization == .authorized || authorization == .limited else { return }
        inventory = await PhotoLibraryService.inventory()
    }

    func refreshAuthorization() {
        let previous = authorization
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        // A new scan is required after returning from Settings or changing selection.
        inventory = nil
        if previous != authorization || (authorization == .limited && !isScanning) {
            if previous != .notDetermined { cancel() }
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

