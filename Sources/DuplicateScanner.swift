import Photos
import CryptoKit
import Foundation

/// Serial worker bounds resource use; Photos delivers streamed resource bytes.
actor DuplicateScanner {
    func scan(progress: @escaping @Sendable (Int, Int) async -> Void) async throws -> [AssetRecord] {
        try Task.checkCancellation()
        let assets = PHAsset.fetchAssets(with: nil)
        var records: [AssetRecord] = []
        for index in 0..<assets.count {
            try Task.checkCancellation()
            let asset = assets.object(at: index)
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
            records.append(AssetRecord(id: asset.localIdentifier,
                                       filename: resources.first?.originalFilename ?? "Untitled asset",
                                       mediaType: asset.mediaType.rawValue,
                                       favorite: asset.isFavorite,
                                       createdAt: asset.creationDate,
                                       resources: fingerprints,
                                       issue: issue,
                                       isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot)))
            await progress(index + 1, assets.count)
        }
        try Task.checkCancellation()
        return records
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
