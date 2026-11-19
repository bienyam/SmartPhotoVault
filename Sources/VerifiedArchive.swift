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
    case unsupportedPhoto, missingFile, conflict, verification, sameFolder, unavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedPhoto: "Only single-resource JPEG and HEIC originals available on this iPhone can be copied."
        case .missingFile: "Choose an accessible regular file."
        case .conflict: "A file with that name already exists. Choose a different folder."
        case .verification: "The copied bytes did not match the original."
        case .sameFolder: "Choose a different folder to test restoring a copy."
        case .unavailable: "The selected location could not be opened."
        }
    }
}

enum VerifiedArchive {
    static func copy(_ item: ArchiveItem, to folder: URL) throws -> ArchiveReceipt {
        try scoped(folder) {
            guard !item.name.isEmpty, item.name != ".", item.name != "..",
                  !item.name.contains("/") else { throw ArchiveError.missingFile }
            let destination = folder.appendingPathComponent(item.name)
            let fingerprint: ArchiveFingerprint
            switch item.source {
            case let .file(source):
                fingerprint = try scoped(source) {
                    try coordinateCopy(from: source, to: destination) { input, output in
                        try writeVerified(to: output) { try copyFile(input, to: $0) }
                    }
                }
            case let .photo(id, expected):
                fingerprint = try coordinateWrite(to: destination) { output in
                    try writeVerified(to: output) { temporary in
                        let result = try copyPhoto(id, to: temporary)
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

    static func restore(_ receipt: ArchiveReceipt, to folder: URL) throws -> URL {
        guard receipt.folder.standardizedFileURL != folder.standardizedFileURL else { throw ArchiveError.sameFolder }
        return try scoped(receipt.folder) {
            try scoped(folder) {
                let destination = folder.appendingPathComponent(receipt.url.lastPathComponent)
                return try coordinateCopy(from: receipt.url, to: destination) { input, output in
                    _ = try writeVerified(to: output) { temporary in
                        let result = try copyFile(input, to: temporary)
                        guard result == receipt.fingerprint else { throw ArchiveError.verification }
                        return result
                    }
                    return destination
                }
            }
        }
    }

    static func original(for asset: PHAsset) -> PHAssetResource? {
        guard asset.mediaType == .image, !asset.mediaSubtypes.contains(.photoLive) else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        guard resources.count == 1, let resource = resources.first, resource.type == .photo,
              let type = UTType(resource.uniformTypeIdentifier),
              type.conforms(to: .jpeg) || type.conforms(to: .heic) else { return nil }
        return resource
    }

    private static func copyPhoto(_ id: String, to temporary: URL) throws -> ArchiveFingerprint {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              let resource = original(for: asset) else { throw ArchiveError.unsupportedPhoto }

        let writer = try ArchiveWriter(url: temporary)
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let completion = DispatchSemaphore(value: 0)
        let manager = PHAssetResourceManager.default()
        let request = manager.requestData(for: resource, options: options) { data in
            writer.append(data)
        } completionHandler: { error in
            writer.finish(error)
            completion.signal()
        }
        if completion.wait(timeout: .now() + 120) == .timedOut {
            writer.finish(ArchiveError.unavailable)
            manager.cancelDataRequest(request)
        }
        return try writer.result()
    }

    private static func copyFile(_ source: URL, to temporary: URL) throws -> ArchiveFingerprint {
        let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attributes.isRegularFile == true, attributes.isSymbolicLink != true else { throw ArchiveError.missingFile }
        let writer = try ArchiveWriter(url: temporary)
        do {
            let original = try read(source) { writer.append($0) }
            writer.finish(nil)
            guard try writer.result() == original else { throw ArchiveError.verification }
            return original
        } catch {
            writer.finish(error)
            throw error
        }
    }

    private static func writeVerified(to destination: URL, copy: (URL) throws -> ArchiveFingerprint) throws -> ArchiveFingerprint {
        let files = FileManager.default
        guard !files.fileExists(atPath: destination.path) else { throw ArchiveError.conflict }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
        defer { try? files.removeItem(at: temporary) }
        let source = try copy(temporary)
        guard try read(temporary) == source else { throw ArchiveError.verification }
        try files.moveItem(at: temporary, to: destination)
        return source
    }

    private static func read(_ url: URL, chunk: (Data) -> Void = { _ in }) throws -> ArchiveFingerprint {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        var bytes: Int64 = 0
        while let data = try handle.read(upToCount: 256 * 1024), !data.isEmpty {
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

private final class ArchiveWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private var hash = SHA256()
    private var bytes: Int64 = 0
    private var error: Error?
    private var closed = false

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw ArchiveError.unavailable }
        handle = try FileHandle(forWritingTo: url)
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, error == nil else { return }
        do {
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
        do { try handle.close() } catch { self.error = self.error ?? error }
    }

    func result() throws -> ArchiveFingerprint {
        lock.lock()
        defer { lock.unlock() }
        if let error { throw error }
        return VerifiedArchive.fingerprint(hash, bytes: bytes)
    }
}
