import SwiftUI
import UIKit
import Photos
import CryptoKit
import ImageIO
import AVFoundation

/// Small pictures of archived items, kept on this device so Get back can show them after the
/// originals are removed from Photos. Made from the photo while it is still in the library, or,
/// for older archives, from the copy itself when its folder or drive is reachable. Never sent anywhere.
enum ArchiveThumbnails {
    static let side: CGFloat = 360

    static var folder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ArchiveThumbnails", isDirectory: true)
    }

    /// One file per photo, named by a hash so identifiers with slashes are safe as file names.
    static func url(for photoID: String) -> URL {
        let name = SHA256.hash(data: Data(photoID.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(name).appendingPathExtension("jpg")
    }

    static func cached(_ photoID: String) -> UIImage? {
        UIImage(contentsOfFile: url(for: photoID).path)
    }

    static func store(_ image: UIImage, for photoID: String) {
        guard let data = image.jpegData(compressionQuality: 0.72) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: url(for: photoID), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Saves pictures for the photos that are still in the library and don't have one yet.
    /// Never throws and never blocks a removal: a missing picture only means a plainer Get back row.
    static func remember(_ photoIDs: [String]) async {
        let missing = Array(Set(photoIDs.filter { !FileManager.default.fileExists(atPath: url(for: $0).path) }))
        guard !missing.isEmpty else { return }
        let access = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard access == .authorized || access == .limited else { return }
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: missing, options: nil)
        var list: [PHAsset] = []
        assets.enumerateObjects { asset, _, _ in list.append(asset) }
        for asset in list {
            if let image = await picture(of: asset) { store(image, for: asset.localIdentifier) }
        }
    }

    /// Starts `remember` without waiting for it.
    static func rememberSoon(_ photoIDs: [String]) {
        guard !photoIDs.isEmpty else { return }
        Task.detached(priority: .utility) { await remember(photoIDs) }
    }

    private static func picture(of asset: PHAsset) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        return await withCheckedContinuation { done in
            PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: side, height: side),
                                                  contentMode: .aspectFill, options: options) { image, _ in
                done.resume(returning: image)
            }
        }
    }

    /// A picture made from an archived file in a folder or on a drive, for archives made before
    /// pictures were kept. Nil when the folder isn't reachable (for example the drive is unplugged).
    static func fromCopy(_ record: ArchivedRecord) -> UIImage? {
        guard record.driveFileID == nil, record.cloud == nil, let bookmark = record.folderBookmark else { return nil }
        var stale = false
        guard let folder = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else { return nil }
        let active = folder.startAccessingSecurityScopedResource()
        defer { if active { folder.stopAccessingSecurityScopedResource() } }
        let file = folder.appendingPathComponent(record.name)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        if let image = imageThumbnail(file) { return image }
        return videoThumbnail(file)
    }

    private static func imageThumbnail(_ file: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: side]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    private static func videoThumbnail(_ file: URL) -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: side, height: side)
        guard let image = try? generator.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// The picture for an archived item: the photo if it's still in the library, else the kept
/// picture, else one made from the copy, else a plain photo or video symbol.
struct ArchivedThumb: View {
    let record: ArchivedRecord
    var side: CGFloat = 140
    @State private var image: UIImage?
    @State private var looked = false
    @State private var inPhotos = false

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if inPhotos, let id = record.photoID {
                    AssetCover(assetID: id, side: side)
                } else {
                    ZStack {
                        Brand.surface
                        Image(systemName: ArchivedDayView.isVideo(record.name) ? "video" : "photo")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .clipped()
            .accessibilityHidden(true)
            .task(id: record.id) { await load() }
    }

    private func inLibrary(_ id: String) -> Bool {
        PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject != nil
    }

    private func load() async {
        guard !looked else { return }
        looked = true
        if let id = record.photoID {
            if inLibrary(id) { inPhotos = true; return }
            if let kept = ArchiveThumbnails.cached(id) { image = kept; return }
        }
        let record = record
        let made = await Task.detached(priority: .utility) { ArchiveThumbnails.fromCopy(record) }.value
        if let made {
            image = made
            if let id = record.photoID { ArchiveThumbnails.store(made, for: id) }
        }
    }
}
