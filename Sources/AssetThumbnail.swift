import SwiftUI
import Photos

/// The thumbnails' shared image manager and the asset look-up, so lists scroll without stalls.
enum Thumbnails {
    /// One caching manager for every thumbnail and cover, so a picture asked for twice comes from its cache.
    static let manager = PHCachingImageManager()

    /// Finds one asset by its identifier off the main thread; the fetch reads the Photos database.
    static func asset(_ id: String) async -> PHAsset? {
        await Task.detached(priority: .userInitiated) {
            PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
        }.value
    }
}

struct AssetThumbnail: View {
    let assetID: String
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?
    @State private var isVisible = false
    @State private var loading: Task<Void, Never>?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Color.secondary.opacity(0.1)
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 64, height: 64)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityHidden(true)
        .onAppear { load() }
        .onDisappear {
            isVisible = false
            loading?.cancel()
            loading = nil
            if let requestID { Thumbnails.manager.cancelImageRequest(requestID) }
            requestID = nil
            image = nil
        }
    }

    private func load() {
        isVisible = true
        guard !assetID.hasPrefix("sample-") else { return }
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard access == .authorized || access == .limited else { return }
        let id = assetID
        loading?.cancel()
        loading = Task {
            let found = await Thumbnails.asset(id)
            guard !Task.isCancelled, isVisible else { return }
            guard let asset = found else {
                image = ArchiveThumbnails.cached(id)
                return
            }
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            requestID = Thumbnails.manager.requestImage(for: asset,
                                                        targetSize: CGSize(width: 192, height: 192),
                                                        contentMode: .aspectFill,
                                                        options: options) { thumbnail, info in
                guard (info?[PHImageCancelledKey] as? Bool) != true, let thumbnail else { return }
                DispatchQueue.main.async {
                    guard isVisible else { return }
                    image = thumbnail
                }
            }
        }
    }
}
