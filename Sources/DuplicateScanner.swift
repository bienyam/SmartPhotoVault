import Photos
import CryptoKit
import Foundation

/// Serial worker bounds resource use; Photos delivers streamed resource bytes.
actor DuplicateScanner {
    /// Albums found by the last completed scan (your own, shared and synced), for the Archive album filter.
    private(set) var lastAlbums: [AlbumInfo] = []

    func scan(progress: @escaping @Sendable (Int, Int) async -> Void) async throws -> [AssetRecord] {
        try await scanProgressively(progress: progress, partial: nil)
    }

    /// Reads the biggest things first, longest videos then the largest photos, and hands back
    /// what it has found every couple of seconds, so the Free up tab fills in within moments
    /// instead of waiting for the whole library.
    func scanProgressively(progress: @escaping @Sendable (Int, Int) async -> Void,
                           partial: (@Sendable ([AssetRecord]) async -> Void)?) async throws -> [AssetRecord] {
        try Task.checkCancellation()
        let fetched = PHAsset.fetchAssets(with: nil)
        var assets: [PHAsset] = []
        assets.reserveCapacity(fetched.count)
        fetched.enumerateObjects { asset, _, _ in assets.append(asset) }
        assets.sort(by: Self.biggestFirst)
        var lastPartial = Date()
        var records: [AssetRecord] = []
        var burstFrameCounts: [String: Int] = [:]
        var albums: [AlbumInfo] = []
        var albumsByAsset: [String: [String]] = [:]
        lastAlbums = []
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        for index in 0..<collections.count {
            try Task.checkCancellation()
            let collection = collections.object(at: index)
            albums.append(AlbumInfo(id: collection.localIdentifier, title: collection.localizedTitle ?? "Untitled album"))
            PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
                albumsByAsset[asset.localIdentifier, default: []].append(collection.localIdentifier)
            }
        }
        let sortedAlbums = albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        for index in assets.indices {
            try Task.checkCancellation()
            let asset = assets[index]
            let resources = PHAssetResource.assetResources(for: asset)
            var fingerprints: [ResourceFingerprint] = []
            var issue: String?
            do {
                for resource in resources {
                    try Task.checkCancellation()
                    fingerprints.append(try await hash(resource))
                }
                if resources.isEmpty { issue = "No accessible resources." }
            } catch is CancellationError { throw CancellationError() }
            catch { issue = error.localizedDescription }
            // With Optimize iPhone Storage on, originals often live only in iCloud and can't be read
            // without downloading. Record their size so they still show up, marked "in iCloud".
            let cloudBytes = issue == nil ? nil : Self.reportedSize(of: resources)
            var frames: Int?
            if let burst = asset.burstIdentifier {
                if let known = burstFrameCounts[burst] {
                    frames = known
                } else {
                    // The default fetch returns one photo per burst; count the hidden frames too.
                    let options = PHFetchOptions()
                    options.includeAllBurstAssets = true
                    let count = PHAsset.fetchAssets(withBurstIdentifier: burst, options: options).count
                    burstFrameCounts[burst] = count
                    frames = count
                }
            }
            records.append(AssetRecord(id: asset.localIdentifier,
                                       filename: resources.first?.originalFilename ?? "Untitled asset",
                                       mediaType: asset.mediaType.rawValue,
                                       favorite: asset.isFavorite,
                                       createdAt: asset.creationDate,
                                       resources: fingerprints,
                                       issue: issue,
                                       isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
                                       subtypes: asset.mediaSubtypes.rawValue,
                                       animated: asset.playbackStyle == .imageAnimated,
                                       burstID: asset.burstIdentifier,
                                       burstFrames: frames,
                                       pixelWidth: asset.pixelWidth,
                                       pixelHeight: asset.pixelHeight,
                                       hasLocation: asset.location != nil,
                                       albumIDs: albumsByAsset[asset.localIdentifier] ?? [],
                                       latitude: asset.location.map { PlaceArea.rounded($0.coordinate.latitude) },
                                       longitude: asset.location.map { PlaceArea.rounded($0.coordinate.longitude) },
                                       cloudBytes: cloudBytes))
            await progress(index + 1, assets.count)
            if let partial, Date().timeIntervalSince(lastPartial) > 1.5 {
                lastPartial = Date()
                await partial(records)
            }
        }
        try Task.checkCancellation()
        lastAlbums = sortedAlbums
        return records
    }

    /// The size Photos reports for an item's original files, without reading or downloading them.
    /// PhotoKit has no public size property, so this reads the `fileSize` value Photos keeps on each
    /// resource, checking first that it exists. Nil if Photos doesn't report one.
    static func reportedSize(of resources: [PHAssetResource]) -> Int64? {
        var total: Int64 = 0
        for resource in resources {
            guard resource.responds(to: NSSelectorFromString("fileSize")),
                  let size = (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value, size > 0 else { continue }
            total += size
        }
        return total > 0 ? total : nil
    }

    /// Videos before photos; longer videos first; then photos by pixel count. A cheap stand-in for
    /// file size, which PhotoKit only reveals by reading the file.
    static func biggestFirst(_ lhs: PHAsset, _ rhs: PHAsset) -> Bool {
        let leftVideo = lhs.mediaType == .video, rightVideo = rhs.mediaType == .video
        if leftVideo != rightVideo { return leftVideo }
        if leftVideo, lhs.duration != rhs.duration { return lhs.duration > rhs.duration }
        let left = lhs.pixelWidth * lhs.pixelHeight, right = rhs.pixelWidth * rhs.pixelHeight
        if left != right { return left > right }
        return lhs.localIdentifier < rhs.localIdentifier
    }

    /// Re-reads every resource of one asset so a removal can be checked against the scan.
    /// Returns nil when the asset is gone or has no readable resources.
    func fingerprint(for id: String) async throws -> String? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        guard !resources.isEmpty else { return nil }
        var fingerprints: [ResourceFingerprint] = []
        for resource in resources { fingerprints.append(try await hash(resource)) }
        return AssetRecord(id: id, filename: "", mediaType: asset.mediaType.rawValue, favorite: asset.isFavorite,
                           createdAt: nil, resources: fingerprints, issue: nil).fingerprint
    }

    func archiveFingerprint(for id: String) async throws -> ResourceFingerprint {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              let resource = VerifiedArchive.original(for: asset) else { throw ArchiveError.unsupportedPhoto }
        return try await hash(resource)
    }

    private func hash(_ resource: PHAssetResource) async throws -> ResourceFingerprint {
        let state = ResourceHashState()
        let manager = PHAssetResourceManager.default()
        return try await withCheckedThrowingContinuation { continuation in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = false
            manager.requestData(for: resource, options: options) { data in
                state.append(data)
            } completionHandler: { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: state.finish(type: resource.type.rawValue)) }
            }
        }
    }
}

private final class ResourceHashState: @unchecked Sendable {
    private let lock = NSLock()
    private var hasher = SHA256()
    private var bytes: Int64 = 0
    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        hasher.update(data: data)
        bytes += Int64(data.count)
    }
    func finish(type: Int) -> ResourceFingerprint {
        lock.lock()
        defer { lock.unlock() }
        return ResourceFingerprint(type: type, digest: hasher.finalize().map { String(format: "%02x", $0) }.joined(), bytes: bytes)
    }
}
