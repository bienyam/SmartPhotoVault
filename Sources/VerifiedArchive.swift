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
    /// The size the scan recorded, when known. OneDrive needs it before the upload starts.
    var size: Int64? = nil

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
        case .unsupportedPhoto: "Only JPEG and HEIC photos and single-file videos available on this \(Device.name) can be copied. Live Photos, slo-mo and edited videos aren't supported yet."
        case .missingFile: "Choose an accessible regular file."
        case .conflict: "A file with that name already exists. Choose a different folder."
        case .verification: "The copied bytes did not match the original."
        case .sameFolder: "Choose a different folder to test restoring a copy."
        case .unavailable: "The selected location could not be opened."
        case .iCloudDownload: "iCloud didn't send this item. Use Wi-Fi, turn off Low Power Mode, and if you're not on Wi-Fi turn on Settings › Photos › Cellular Data. Then try again."
        case .wifi: "Join the same Wi-Fi network as your home server and try again."
        }
    }
}

enum VerifiedArchive {
    /// `flush: false` leaves the drive's write cache alone; the caller must then call `flushDrive` once
    /// after the whole batch, before any original may be deleted.
    static func copy(_ item: ArchiveItem, to folder: URL, wifi: ArchiveWiFi? = nil, flush: Bool = true) throws -> ArchiveReceipt {
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
                        try writeVerified(to: output, wifi: wifi) { try copyFile(input, to: $0, wifi: wifi, flush: flush) }
                    }
                }
            case let .photo(id, expected):
                fingerprint = try coordinateWrite(to: destination) { output in
                    try writeVerified(to: output, wifi: wifi) { temporary in
                        let result = try copyPhoto(id, to: temporary, wifi: wifi, flush: flush)
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
    /// `offDevice` is only ever false in tests, which have no second volume to write to.
    static func checkCopy(named name: String, in folder: URL, expected: ArchiveFingerprint,
                          wifi: ArchiveWiFi?, offDevice: Bool = true) throws -> CopyStamp {
        try wifi?.requireConnection()
        return try scoped(folder) {
            try coordinateRead(folder.appendingPathComponent(name)) { url in
                let before = try stamp(url, offDevice: offDevice)
                guard before.bytes == expected.bytes,
                      try read(url, wifi: wifi, skipCache: true) == expected else { throw ArchiveProofError.copyDiffers }
                guard try stamp(url, offDevice: offDevice) == before else { throw ArchiveProofError.changedSinceCheck }
                return before
            }
        }
    }

    /// The copy's current size and date, without reading its contents.
    static func copyStamp(named name: String, in folder: URL, wifi: ArchiveWiFi?, offDevice: Bool = true) throws -> CopyStamp {
        try wifi?.requireConnection()
        return try scoped(folder) {
            try coordinateRead(folder.appendingPathComponent(name)) { try stamp($0, offDevice: offDevice) }
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

    private static func stamp(_ url: URL, offDevice: Bool) throws -> CopyStamp {
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
        if values.isUbiquitousItem == true {
            guard values.ubiquitousItemIsUploaded == true else { throw ArchiveProofError.notUploaded }
        } else if offDevice, !isOnAnotherVolume(fresh) {
            throw ArchiveProofError.notConfirmable
        }
        return CopyStamp(bytes: Int64(size), modified: values.contentModificationDate, checksum: nil)
    }

    /// True for a plugged-in drive or a server: storage that is not this iPhone's own. Cloud apps other than
    /// iCloud keep files on the iPhone until they upload and don't say when they have, so their folders don't
    /// count. Anything unclear counts as no.
    private static func isOnAnotherVolume(_ url: URL) -> Bool {
        let own = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        guard let mine = try? own.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier,
              let values = try? url.resourceValues(forKeys: [.volumeIdentifierKey, .volumeIsInternalKey]),
              let theirs = values.volumeIdentifier else { return false }
        if values.volumeIsInternal == true || mine.isEqual(theirs) { return false }
        let path = url.standardizedFileURL.path
        return !["/File Provider Storage", "/CloudStorage/", "/Containers/"].contains { path.contains($0) }
    }

    private static func copyPhoto(_ id: String, to temporary: URL, wifi: ArchiveWiFi?, flush: Bool) throws -> ArchiveFingerprint {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              let resource = original(for: asset) else { throw ArchiveError.unsupportedPhoto }
        defer { ArchiveLive.shared.downloading(id, nil) }
        // Videos can be large and iCloud or a home server may be slow, so a working copy gets plenty of time.
        let limit: TimeInterval = asset.mediaType == .video ? 3600 : 600
        // First way: stream the original straight into the copy. With Optimize iPhone Storage on,
        // Photos downloads it from iCloud as it goes.
        switch try stream(resource, id: id, to: temporary, wifi: wifi, flush: flush,
                          quiet: ArchiveActivity.firstTryLimit, limit: limit) {
        case let .done(fingerprint):
            return fingerprint
        case let .stalled(receivedSome):
            // Photos sometimes queues an iCloud download and never starts it. For a photo that sent
            // nothing at all, ask Photos for the original a second way before giving up.
            guard !receivedSome, asset.mediaType == .image else { throw ArchiveError.iCloudDownload }
            return try originalImage(asset, id: id, to: temporary, wifi: wifi, flush: flush, limit: limit)
        }
    }

    private enum StreamResult { case done(ArchiveFingerprint), stalled(receivedSome: Bool) }

    private static func stream(_ resource: PHAssetResource, id: String, to temporary: URL, wifi: ArchiveWiFi?, flush: Bool,
                               quiet: TimeInterval, limit: TimeInterval) throws -> StreamResult {
        let writer = try ArchiveWriter(url: temporary, wifi: wifi, flush: flush)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let activity = ArchiveActivity()
        options.progressHandler = { fraction in
            activity.progressed(fraction)
            ArchiveLive.shared.downloading(id, fraction)
        }
        let completion = DispatchSemaphore(value: 0)
        let manager = PHAssetResourceManager.default()
        let request = manager.requestData(for: resource, options: options) { data in
            activity.received()
            writer.append(data)
        } completionHandler: { error in
            writer.finish(error)
            completion.signal()
        }
        let started = Date()
        while completion.wait(timeout: .now() + 2) == .timedOut {
            // Only real progress counts: Photos can report 0% over and over without downloading anything.
            if activity.silentFor > quiet || Date().timeIntervalSince(started) > limit {
                writer.finish(ArchiveError.iCloudDownload)
                manager.cancelDataRequest(request)
                return .stalled(receivedSome: activity.gotData)
            }
        }
        do {
            return .done(try writer.result())
        } catch let error as NSError where error.domain == PHPhotosErrorDomain {
            throw ArchiveError.iCloudDownload
        }
    }

    /// The second way: Photos' image download, which fetches the unedited original from iCloud.
    private static func originalImage(_ asset: PHAsset, id: String, to temporary: URL, wifi: ArchiveWiFi?, flush: Bool,
                                      limit: TimeInterval) throws -> ArchiveFingerprint {
        let options = PHImageRequestOptions()
        options.version = .original
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        let activity = ArchiveActivity()
        options.progressHandler = { progress, _, _, _ in
            activity.progressed(progress)
            ArchiveLive.shared.downloading(id, progress)
        }
        let box = ArchiveImageBox()
        let completion = DispatchSemaphore(value: 0)
        let request = PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
            box.set(data, error: info?[PHImageErrorKey] as? Error)
            completion.signal()
        }
        let started = Date()
        while completion.wait(timeout: .now() + 2) == .timedOut {
            if activity.silentFor > ArchiveActivity.stallLimit || Date().timeIntervalSince(started) > limit {
                PHImageManager.default().cancelImageRequest(request)
                throw ArchiveError.iCloudDownload
            }
        }
        guard let data = box.data, !data.isEmpty else { throw ArchiveError.iCloudDownload }
        let writer = try ArchiveWriter(url: temporary, wifi: wifi, flush: flush)
        writer.append(data)
        writer.finish(nil)
        return try writer.result()
    }

    private static func copyFile(_ source: URL, to temporary: URL, wifi: ArchiveWiFi?, flush: Bool = true) throws -> ArchiveFingerprint {
        let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw ArchiveError.missingFile }
        let writer = try ArchiveWriter(url: temporary, wifi: wifi, flush: flush)
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
        // The bytes were flushed to the destination; it must hold exactly as many as the source had.
        guard try storedSize(of: temporary) == source.bytes else { throw ArchiveError.verification }
        try wifi?.requireConnection()
        try files.moveItem(at: temporary, to: destination)
        return source
    }

    /// Makes the drive write out everything it is holding in its cache. One call covers every file
    /// copied to that drive, so a batch is flushed once at the end instead of after each file.
    static func flushDrive(_ file: URL, in folder: URL) throws {
        try scoped(folder) {
            let descriptor = open(file.path, O_RDONLY)
            guard descriptor >= 0 else { throw ArchiveError.unavailable }
            defer { close(descriptor) }
            if fcntl(descriptor, F_FULLFSYNC) == -1, fsync(descriptor) == -1, errno != ENOTSUP, errno != EINVAL {
                throw ArchiveError.unavailable
            }
        }
    }

    /// The size the destination reports for a file, fresh rather than remembered.
    static func storedSize(of url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else { throw ArchiveError.verification }
        return size.int64Value
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

/// When a copy last received anything, so a stuck one can be told from a slow one.
final class ArchiveActivity: @unchecked Sendable {
    /// No data and no download progress for this long means the copy is stuck.
    static let stallLimit: TimeInterval = 180
    /// The first way of reading a photo gets less time before the second way is tried.
    static let firstTryLimit: TimeInterval = 60
    private let lock = NSLock()
    private var last = Date()
    private var fraction = 0.0
    private var data = false

    func touch() { lock.lock(); last = Date(); lock.unlock() }

    /// Counts only when the download moved forward; a repeated 0% is not progress.
    func progressed(_ value: Double) {
        lock.lock(); defer { lock.unlock() }
        if value > fraction + 0.0001 { fraction = value; last = Date() }
    }

    func received() { lock.lock(); data = true; last = Date(); lock.unlock() }

    var gotData: Bool {
        lock.lock(); defer { lock.unlock() }
        return data
    }

    var silentFor: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return Date().timeIntervalSince(last)
    }
}

/// Holds what Photos hands back on another thread until the copy reads it.
final class ArchiveImageBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    private var failure: Error?

    func set(_ data: Data?, error: Error?) { lock.lock(); value = data; failure = error; lock.unlock() }
    var data: Data? { lock.lock(); defer { lock.unlock() }; return value }
}

/// What a copy run is doing right now, for the progress screen: bytes written so far, and items
/// still downloading from iCloud with how far along they are. Safe to use from any thread.
final class ArchiveLive: @unchecked Sendable {
    static let shared = ArchiveLive()
    private let lock = NSLock()
    private var written: Int64 = 0
    private var sent: Int64 = 0
    private var downloads: [String: Double] = [:]

    func reset() { lock.lock(); written = 0; sent = 0; downloads = [:]; lock.unlock() }
    func wrote(_ count: Int) { lock.lock(); written += Int64(count); lock.unlock() }
    /// Bytes accepted by OneDrive or Dropbox.
    func uploaded(_ count: Int) { lock.lock(); sent += Int64(count); lock.unlock() }

    var uploadedBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return sent
    }
    /// Pass nil when the item is done.
    func downloading(_ id: String, _ fraction: Double?) {
        lock.lock(); downloads[id] = fraction; lock.unlock()
    }

    var now: (written: Int64, downloading: Int, fraction: Double) {
        lock.lock(); defer { lock.unlock() }
        let average = downloads.isEmpty ? 0 : downloads.values.reduce(0, +) / Double(downloads.count)
        return (written, downloads.count, average)
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

    private let flush: Bool

    init(url: URL, wifi: ArchiveWiFi?, flush: Bool = true) throws {
        self.wifi = wifi
        self.flush = flush
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
            ArchiveLive.shared.wrote(data.count)
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
        if flush, error == nil, fcntl(handle.fileDescriptor, F_FULLFSYNC) == -1, fsync(handle.fileDescriptor) == -1,
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
