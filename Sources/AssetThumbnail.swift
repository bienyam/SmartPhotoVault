import SwiftUI
import Photos

struct AssetThumbnail: View {
    let assetID: String
    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID?
    @State private var isVisible = false

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
            if let requestID { PHImageManager.default().cancelImageRequest(requestID) }
            requestID = nil
            image = nil
        }
    }

    private func load() {
        isVisible = true
        guard !assetID.hasPrefix("sample-") else { return }
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard access == .authorized || access == .limited else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = assets.firstObject else { return }
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        requestID = PHImageManager.default().requestImage(for: asset,
                                                        targetSize: CGSize(width: 192, height: 192),
                                                        contentMode: .aspectFill,
                                                        options: options) { thumbnail, info in
            guard (info?[PHImageCancelledKey] as? Bool) != true else { return }
            DispatchQueue.main.async {
                guard isVisible else { return }
                image = thumbnail
            }
        }
    }
}
