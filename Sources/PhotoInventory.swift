import Photos
import Foundation

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
        authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        // A new scan is required after returning from Settings or changing selection.
        inventory = nil
    }
}

