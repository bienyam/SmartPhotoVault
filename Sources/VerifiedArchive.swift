import CryptoKit
import Foundation
import Photos
import UniformTypeIdentifiers

enum ArchiveSource: Sendable {
    case photo(String, expected: ResourceFingerprint?)
    case file(URL)
}

struct ArchiveItem: Identifiable, Sendable {
    let id: String
    let name: String
    let source: ArchiveSource

    var sourceLabel: String {
        switch source {
        case .file: "Files"
        case let .photo(_, expected):
            if let expected { "Photos · \(ByteCountFormatter.string(fromByteCount: expected.bytes, countStyle: .file))" }
            else { "Photos" }
        }
    }
}

struct ArchiveFingerprint: Equatable, Sendable {
    let bytes: Int64
    let digest: String
}

struct ArchiveReceipt: Identifiable, Sendable {
    let id: String
    let url: URL
    let folder: URL
    let fingerprint: ArchiveFingerprint
}

enum ArchiveError: LocalizedError {
    case unsupportedPhoto, missingFile, conflict, verification, sameFolder, unavailable, wifi, iCloudDownload

    var errorDescription: String? {
        switch self {
        case .unsupportedPhoto: "Only JPEG and HEIC photos and single-file videos available on this iPhone can be copied. Live Photos, slo-mo and edited videos aren't supported yet."
        case .missingFile: "Choose an accessible regular file."
        case .conflict: "A file with that name already exists. Choose a different folder."
        case .verification: "The copied bytes did not match the original."
        case .sameFolder: "Choose a different folder to test restoring a copy."
        case .unavailable: "The selected location could not be opened."
        case .iCloudDownload: "This item is stored in iCloud and couldn't be downloaded. Check your internet connection and try again."
        case .wifi: "Join the same Wi-Fi network as your home server and try again."
        }
    }
}

enum VerifiedArchive {
    static func copy(_ item: ArchiveItem, to folder: URL, wifi: ArchiveWiFi? = nil) throws -> ArchiveReceipt {
        try wifi?.requireConnection()
        return try scoped(folder) {
            guard !item.name.isEmpty, item.name != ".", item.name != "..",
                  !item.name.contains("/") else { throw ArchiveError.missingFile }
            let destination = folder.appendingPathComponent(item.name)
            let fingerprint: ArchiveFingerprint
            switch item.source {
            case let .file(source):
                fingerprint = try scoped(source) {
                    try coordinateCopy(from: source, to: destination) { input, output in
                        try writeVerified(to: output, wifi: wifi) { try copyFile(input, to: $0, wifi: wifi) }
                    }
                }
            case let .photo(id, expected):
                fingerprint = try coordinateWrite(to: destination) { output in
                    try writeVerified(to: output, wifi: wifi) { temporary in
                        let result = try copyPhoto(id, to: temporary, wifi: wifi)
                        if let expected, result != ArchiveFingerprint(bytes: expected.bytes, digest: expected.digest) {
                            throw ArchiveError.verification
                        }
                        return result
                    }
                }
            }
            return ArchiveReceipt(id: item.id, url: destination, folder: folder, fingerprint: fingerprint)
        }
    }

    static func restore(_ receipt: ArchiveReceipt, to folder: URL, wifi: ArchiveWiFi? = nil) throws -> URL {
        try wifi?.requireConnection()
        guard receipt.folder.standardizedFileURL != folder.standardizedFileURL else { throw ArchiveError.sameFolder }
        return try scoped(receipt.folder) {
            try scoped(folder) {
                let destination = folder.appendingPathComponent(receipt.url.lastPathComponent)
                return try coordinateCopy(from: receipt.url, to: destination) { input, output in
                    _ = try writeVerified(to: output, wifi: wifi) { temporary in
                        let result = try copyFile(input, to: temporary, wifi: wifi)
                        guard result == receipt.fingerprint else { throw ArchiveError.verification }
                        return result
                    }
                    return destination
                }
            }
        }
    }

    /// The single original file for a photo (JPEG or HEIC) or a video, or nil when the asset has more
    /// than one resource (Live Photos, slo-mo, edits) and can't be archived as one verified file.
    static func original(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard resources.count == 1, let resource = resources.first,
              let type = UTType(resource.uniformTypeIdentifier) else { return nil }
        switch asset.mediaType {
        case .image:
            guard !asset.mediaSubtypes.contains(.photoLive), resource.type == .photo,
                  type.conforms(to: .jpeg) || type.conforms(to: .heic) else { return nil }
        case .video:
            guard resource.type == .video, type.conforms(to: .movie) else { return nil }
        default:
            return nil
        }
        return resource
    }

    /// Reads a whole archive copy back from where it is stored and compares it with the fingerprint taken
    /// when it was archived. Anything missing, different or not yet uploaded throws.
    static func checkCopy(named name: String, in folder: URL, expected: ArchiveFingerprint,
                          wifi: ArchiveWiFi?) throws -> CopyStamp {
        try wifi?.requireConnection()
        return try scoped(folder) {
            try coordinateRead(folder.appendingPathComponent(name)) { url in
                let before = try stamp(url)
                guard before.bytes == expected.bytes,
                      try read(url, wifi: wifi, skipCache: true) == expected else { throw ArchiveProofError.copyDiffers }
                guard try stamp(url) == before else { throw ArchiveProofError.changedSinceCheck }
                return before
            }
        }
    }

    /// The copy's current size and date, without reading its contents.
    static func copyStamp(named name: String, in folder: URL, wifi: ArchiveWiFi?) throws -> CopyStamp {
        try wifi?.requireConnection()
        return try scoped(folder) {
            try coordinateRead(folder.appendingPathComponent(name)) { try stamp($0) }
        }
    }

    /// Reads the whole original from Photos again (downloading it from iCloud if needed) and hashes it.
    static func originalFingerprint(_ id: String) throws -> ArchiveFingerprint {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              let resource = original(for: asset) else { throw ArchiveProofError.originalChanged }
        let sink = ArchiveHasher()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let completion = DispatchSemaphore(value: 0)
        let manager = PHAssetResourceManager.default()
        let request = manager.requestData(for: resource, options: options) { data in
            sink.append(data)
        } completionHandler: { error in
            sink.finish(error)
            completion.signal()
        }
        let limit: DispatchTimeInterval = asset.mediaType == .video ? .seconds(3600) : .seconds(600)
        if completion.wait(timeout: .now() + limit) == .timedOut {
            sink.finish(ArchiveError.unavailable)
            manager.cancelDataRequest(request)
        }
        do {
            return try sink.result()
        } catch let error as NSError where error.domain == PHPhotosErrorDomain {
            throw ArchiveError.iCloudDownload
        }
    }

    private static func stamp(_ url: URL) throws -> CopyStamp {
        guard FileManager.default.fileExists(atPath: url.path) else { throw ArchiveProofError.copyMissing }
        var fresh = url
        fresh.removeAllCachedResourceValues()
        let values = try fresh.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
                                                        .contentModificationDateKey, .isUbiquitousItemKey,
                                                        .ubiquitousItemIsUploadedKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else {
            throw ArchiveProofError.copyMissing
        }
        // A copy in iCloud Drive that hasn't uploaded exists only on this iPhone.
        if values.isUbiquitousItem == true, values.ubiquitousItemIsUploaded != true {
            throw ArchiveProofError.notUploaded
        }
        return CopyStamp(bytes: Int64(size), modified: values.contentModificationDate, checksum: nil)
    }

    private static func copyPhoto(_ id: String, to temporary: URL, wifi: ArchiveWiFi?) throws -> ArchiveFingerprint {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              let resource = original(for: asset) else { throw ArchiveError.unsupportedPhoto }

        let writer = try ArchiveWriter(url: temporary, wifi: wifi)
        let options = PHAssetResourceRequestOptions()
        // With Optimize iPhone Storage on, the original is often only in iCloud. Archiving needs the
        // full original, so let Photos download it; it streams straight into the archive copy.
        options.isNetworkAccessAllowed = true
        let completion = DispatchSemaphore(value: 0)
        let manager = PHAssetResourceManager.default()
        let request = manager.requestData(for: resource, options: options) { data in
            writer.append(data)
        } completionHandler: { error in
            writer.finish(error)
            completion.signal()
        }
        // Videos can be large, and iCloud downloads or a home server may be slow, so allow plenty of time.
        let limit: DispatchTimeInterval = asset.mediaType == .video ? .seconds(3600) : .seconds(600)
        if completion.wait(timeout: .now() + limit) == .timedOut {
            writer.finish(ArchiveError.unavailable)
            manager.cancelDataRequest(request)
        }
        do {
            return try writer.result()
        } catch let error as NSError where error.domain == PHPhotosErrorDomain {
            throw ArchiveError.iCloudDownload
        }
    }

    private static func copyFile(_ source: URL, to temporary: URL, wifi: ArchiveWiFi?) throws -> ArchiveFingerprint {
        let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw ArchiveError.missingFile }
        let writer = try ArchiveWriter(url: temporary, wifi: wifi)
        do {
            let original = try read(source, wifi: wifi) { writer.append($0) }
            writer.finish(nil)
            guard try writer.result() == original else { throw ArchiveError.verification }
            return original
        } catch {
            writer.finish(error)
            throw error
        }
    }

    private static func writeVerified(to destination: URL, wifi: ArchiveWiFi?, copy: (URL) throws -> ArchiveFingerprint) throws -> ArchiveFingerprint {
        try wifi?.requireConnection()
        let files = FileManager.default
        guard !files.fileExists(atPath: destination.path) else { throw ArchiveError.conflict }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
        defer { try? files.removeItem(at: temporary) }
        let source = try copy(temporary)
        guard try read(temporary, wifi: wifi) == source else { throw ArchiveError.verification }
        try wifi?.requireConnection()
        try files.moveItem(at: temporary, to: destination)
        return source
    }

    private static func read(_ url: URL, wifi: ArchiveWiFi?, skipCache: Bool = false,
                             chunk: (Data) -> Void = { _ in }) throws -> ArchiveFingerprint {
        try wifi?.requireConnection()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // Asks iOS to read from the drive itself rather than from memory.
        if skipCache { _ = fcntl(handle.fileDescriptor, F_NOCACHE, 1) }
        var hash = SHA256()
        var bytes: Int64 = 0
        while true {
            try wifi?.requireConnection()
            guard let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty else { break }
            hash.update(data: data)
            bytes += Int64(data.count)
            chunk(data)
        }
        return fingerprint(hash, bytes: bytes)
    }

    fileprivate static func fingerprint(_ hash: SHA256, bytes: Int64) -> ArchiveFingerprint {
        ArchiveFingerprint(bytes: bytes, digest: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }

    private static func scoped<T>(_ url: URL, work: () throws -> T) rethrows -> T {
        let active = url.startAccessingSecurityScopedResource()
        defer { if active { url.stopAccessingSecurityScopedResource() } }
        return try work()
    }

    private static func coordinateWrite<T>(to url: URL, work: (URL) throws -> T) throws -> T {
        let coordinator = NSFileCoordinator()
        var error: NSError?
        var result: Result<T, Error>?
        coordinator.coordinate(writingItemAt: url, options: [], error: &error) { accessibleURL in
            result = Result { try work(accessibleURL) }
        }
        if let error { throw error }
        guard let result else { throw ArchiveError.unavailable }
        return try result.get()
    }

    private static func coordinateRead<T>(_ url: URL, work: (URL) throws -> T) throws -> T {
        var error: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &error) { accessibleURL in
            result = Result { try work(accessibleURL) }
        }
        if let error { throw error }
        guard let result else { throw ArchiveError.unavailable }
        return try result.get()
    }

    private static func coordinateCopy<T>(from source: URL, to destination: URL, work: (URL, URL) throws -> T) throws -> T {
        guard source.standardizedFileURL != destination.standardizedFileURL else { throw ArchiveError.conflict }
        var error: NSError?
        var result: Result<T, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], writingItemAt: destination,
                                       options: [], error: &error) { input, output in
            result = Result { try work(input, output) }
        }
        if let error { throw error }
        guard let result else { throw ArchiveError.unavailable }
        return try result.get()
    }
}

/// Hashes an original as Photos hands it over, keeping nothing.
private final class ArchiveHasher: @unchecked Sendable {
    private let lock = NSLock()
    private var hash = SHA256()
    private var bytes: Int64 = 0
    private var error: Error?
    private var closed = false

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        hash.update(data: data)
        bytes += Int64(data.count)
    }

    func finish(_ failure: Error?) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        error = failure
    }

    func result() throws -> ArchiveFingerprint {
        lock.lock()
        defer { lock.unlock() }
        if let error { throw error }
        return VerifiedArchive.fingerprint(hash, bytes: bytes)
    }
}

private final class ArchiveWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let wifi: ArchiveWiFi?
    private var hash = SHA256()
    private var bytes: Int64 = 0
    private var error: Error?
    private var closed = false

    init(url: URL, wifi: ArchiveWiFi?) throws {
        self.wifi = wifi
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ArchiveError.unavailable }
        handle = try FileHandle(forWritingTo: url)
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, error == nil else { return }
        do {
            try wifi?.requireConnection()
            try handle.write(contentsOf: data)
            hash.update(data: data)
            bytes += Int64(data.count)
        } catch {
            self.error = error
        }
    }

    func finish(_ failure: Error?) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        error = error ?? failure
        // Push the bytes out to the drive itself before they are read back and checked.
        if error == nil, fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1, fsync(handle.fileDescriptor) == -1,
           errno != ENOTSUP, errno != EINVAL {
            error = ArchiveError.unavailable
        }
        do { try handle.close() } catch { self.error = self.error ?? error }
    }

    func result() throws -> ArchiveFingerprint {
        lock.lock()
        defer { lock.unlock() }
        if let error { throw error }
        return VerifiedArchive.fingerprint(hash, bytes: bytes)
    }
}
