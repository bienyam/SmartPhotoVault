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
    /// Set when this stands for one file of a Photos item kept as several (a Live Photo's video, an
    /// edit): Photos' resource type of that file. Nil for a whole item.
    var part: Int? = nil
    /// The scan's fingerprint of every file of a Live Photo or edited photo. Nil for a single-file item.
    var expectedParts: [ResourceFingerprint]? = nil

    var sourceLabel: String {
        switch source {
        case .file: "Files"
        case let .photo(_, expected):
            if let expectedParts, !expectedParts.isEmpty {
                "Photos · \(ByteCountFormatter.string(fromByteCount: expectedParts.reduce(0) { $0 + $1.bytes }, countStyle: .file))"
            } else if let expected { "Photos · \(ByteCountFormatter.string(fromByteCount: expected.bytes, countStyle: .file))" }
            else { "Photos" }
        }
    }

    /// The same item stored under another name.
    func named(_ name: String) -> ArchiveItem {
        ArchiveItem(id: id, name: name, source: source, size: size, part: part, expectedParts: expectedParts)
    }
}

/// Free names for an item's files in an archive folder. Nothing already there is ever overwritten, and
/// two items of this run with the same name never pick the same one.
enum ArchiveNames {
    /// How many numbers are tried before giving up with "a file with that name already exists".
    static let limit = 9_999

    /// "IMG_0001.HEIC" as number 2 is "IMG_0001 (2).HEIC"; number 1 is the name itself.
    static func numbered(_ name: String, _ number: Int) -> String {
        guard number > 1 else { return name }
        let whole = name as NSString
        let ending = whole.pathExtension
        guard !ending.isEmpty else { return "\(name) (\(number))" }
        return "\(whole.deletingPathExtension) (\(number)).\(ending)"
    }

    private static let lock = NSLock()
    /// Names being written right now, so two copies running side by side never take the same one.
    private static var writing: Set<String> = []

    private static func key(_ name: String, in folder: URL) -> String {
        // Drives are often case-insensitive: "img_0001.heic" and "IMG_0001.HEIC" count as one name.
        folder.appendingPathComponent(name).standardizedFileURL.path.lowercased()
    }

    /// The first number whose names (`names`) are all free: not in the folder and not being written
    /// by another copy. A number whose names are partly taken is used only if `reuse` accepts it.
    /// The names are held until `release`.
    static func reserve(_ names: (Int) throws -> [String], in folder: URL,
                        reuse: (Int) throws -> Bool = { _ in false },
                        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) throws -> (number: Int, names: [String]) {
        for number in 1...limit {
            let candidate = try names(number)
            let keys = candidate.map { key($0, in: folder) }
            lock.lock()
            guard !keys.contains(where: writing.contains) else {
                lock.unlock()
                continue
            }
            let taken = candidate.contains { exists(folder.appendingPathComponent($0)) }
            writing.formUnion(keys)
            lock.unlock()
            guard taken else { return (number, candidate) }
            let usable: Bool
            do {
                usable = try reuse(number)
            } catch {
                release(candidate, in: folder)
                throw error
            }
            if usable { return (number, candidate) }
            release(candidate, in: folder)
        }
        throw ArchiveError.conflict
    }

    static func release(_ names: [String], in folder: URL) {
        lock.lock()
        defer { lock.unlock() }
        writing.subtract(names.map { key($0, in: folder) })
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
    case unsupportedPhoto, missingFile, conflict, verification, sameFolder, unavailable, wifi, iCloudDownload, editedDuringCopy

    var errorDescription: String? {
        switch self {
        case .unsupportedPhoto: "Only JPEG and HEIC photos, with their Live Photo and edit parts, and single-file videos available on this \(Device.name) can be copied. Slo-mo, edited videos and RAW pairs aren't supported yet."
        case .missingFile: "Choose an accessible regular file."
        case .conflict: "A file with that name already exists. Choose a different folder."
        case .verification: "The copied bytes did not match the original."
        case .sameFolder: "Choose a different folder to test restoring a copy."
        case .unavailable: "The selected location could not be opened."
        case .iCloudDownload: "iCloud didn't send this item. Use Wi-Fi, turn off Low Power Mode, and if you're not on Wi-Fi turn on Settings › Photos › Cellular Data. Then try again."
        case .wifi: "Join the same Wi-Fi network as your home server and try again."
        case .editedDuringCopy: "It was edited while it was being copied, so the copy wasn't counted. Copy it again."
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
            case let .photo(id, expected) where item.part != nil && FileManager.default.fileExists(atPath: destination.path):
                // One file of a Live Photo or edited photo is already there, from a try that stopped
                // before every file was copied. Nothing is overwritten: it counts only if reading it
                // back gives exactly the original's bytes.
                fingerprint = try alreadyStored(id, part: item.part, expected: expected, at: destination, wifi: wifi)
            case let .photo(id, expected):
                fingerprint = try coordinateWrite(to: destination) { output in
                    try writeVerified(to: output, wifi: wifi) { temporary in
                        let result = try copyPhoto(id, part: item.part, to: temporary, wifi: wifi, flush: flush)
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

    /// Copies every file of an item to the folder. A single-file item goes exactly the way it always
    /// has. A Live Photo or edited photo is copied file by file, each streamed and checked like a
    /// single file, and counts only when all of them are there: the first failure stops the item.
    ///
    /// A name already used in the folder (IMG_0001 comes back every 10,000 shots) is never overwritten:
    /// the item is stored under the next free number, "IMG_0001 (2).HEIC", and every file of a Live
    /// Photo or edited photo takes the same number ("IMG_0001 (2).MOV", "IMG_0001 (2)_edited.JPG"). The
    /// receipt carries the name actually used.
    static func copyEvery(_ item: ArchiveItem, to folder: URL, wifi: ArchiveWiFi? = nil,
                          flush: Bool = true) throws -> (receipt: ArchiveReceipt, parts: [ArchivedPart]) {
        try scoped(folder) { try copyEveryNamed(item, to: folder, wifi: wifi, flush: flush) }
    }

    private static func copyEveryNamed(_ item: ArchiveItem, to folder: URL, wifi: ArchiveWiFi?,
                                       flush: Bool) throws -> (receipt: ArchiveReceipt, parts: [ArchivedPart]) {
        guard let unnumbered = try ArchiveParts.files(of: item) else {
            let chosen = try ArchiveNames.reserve({ [ArchiveNames.numbered(item.name, $0)] }, in: folder)
            defer { ArchiveNames.release(chosen.names, in: folder) }
            return (try copy(item.named(chosen.names[0]), to: folder, wifi: wifi, flush: flush), [])
        }
        var numbered: [Int: [ArchiveItem]] = [1: unnumbered]
        func files(_ number: Int) throws -> [ArchiveItem] {
            if let known = numbered[number] { return known }
            guard let found = try ArchiveParts.files(of: item.named(ArchiveNames.numbered(item.name, number))) else {
                throw ArchiveError.unsupportedPhoto
            }
            numbered[number] = found
            return found
        }
        // A number whose files are partly there already is used again only when each of those is
        // exactly this item's file, from a try that stopped before every file was copied.
        let chosen = try ArchiveNames.reserve({ try files($0).map(\.name) }, in: folder,
                                              reuse: { number in try files(number).allSatisfy { try holds($0, in: folder, wifi: wifi) } })
        defer { ArchiveNames.release(chosen.names, in: folder) }
        return try copyParts(try files(chosen.number), to: folder, wifi: wifi, flush: flush)
    }

    /// True when the file isn't there yet, or is already there holding exactly this part's original.
    /// A different file under the name is someone else's and is left alone.
    private static func holds(_ file: ArchiveItem, in folder: URL, wifi: ArchiveWiFi?) throws -> Bool {
        let destination = folder.appendingPathComponent(file.name)
        guard FileManager.default.fileExists(atPath: destination.path) else { return true }
        guard case let .photo(id, expected) = file.source, file.part != nil else { return false }
        // A different size can't be the same file; no need to read it.
        if let expected, (try? storedSize(of: destination)) != expected.bytes { return false }
        do {
            _ = try alreadyStored(id, part: file.part, expected: expected, at: destination, wifi: wifi)
            return true
        } catch ArchiveError.conflict {
            return false
        }
    }

    private static func copyParts(_ files: [ArchiveItem], to folder: URL, wifi: ArchiveWiFi?,
                                  flush: Bool) throws -> (receipt: ArchiveReceipt, parts: [ArchivedPart]) {
        let receipts = try ArchiveParts.every(files) { try copy($0, to: folder, wifi: wifi, flush: flush) }
        // An edit made while the files were being copied would leave parts of two different edits.
        try ArchiveParts.requireSameEdit(files, receipts.map { $0.fingerprint })
        let stored = receipts.map { StoredPart(name: $0.url.lastPathComponent, fingerprint: $0.fingerprint) }
        return (receipts[0], ArchiveParts.parts(files, stored))
    }

    /// The files of a Live Photo or an edited photo, original still first. Nil for anything kept as one
    /// file (see `original(for:)`) and for combinations that can't be archived yet.
    static func plan(for asset: PHAsset) -> [PHAssetResource]? {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let types = ArchivePlan.parts(mediaType: asset.mediaType.rawValue, types: resources.map { $0.type.rawValue }),
              let still = resources.first(where: { $0.type == .photo }),
              let type = UTType(still.uniformTypeIdentifier),
              type.conforms(to: .jpeg) || type.conforms(to: .heic) else { return nil }
        let ordered = types.compactMap { wanted in resources.first { $0.type.rawValue == wanted } }
        return ordered.count == resources.count ? ordered : nil
    }

    /// The file that gives an item its name: the single original, or a Live or edited photo's original still.
    static func primary(for asset: PHAsset) -> PHAssetResource? {
        original(for: asset) ?? plan(for: asset)?.first
    }

    /// The file to read for an item: its single original, or the named part of a Live or edited photo.
    static func file(of asset: PHAsset, part: Int?) -> PHAssetResource? {
        guard let part else { return original(for: asset) }
        return plan(for: asset)?.first { $0.type.rawValue == part }
    }

    /// A file of this name is already in the folder. It counts as this part's copy only when it holds
    /// exactly the original's bytes, read back in full from the destination.
    private static func alreadyStored(_ id: String, part: Int?, expected: ResourceFingerprint?, at destination: URL,
                                      wifi: ArchiveWiFi?) throws -> ArchiveFingerprint {
        let original = try originalFingerprint(id, part: part)
        if let expected, original != ArchiveFingerprint(bytes: expected.bytes, digest: expected.digest) {
            throw ArchiveError.verification
        }
        let stored = try coordinateRead(destination) { try read($0, wifi: wifi, skipCache: true) }
        guard stored == original else { throw ArchiveError.conflict }
        return original
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
    ///
    /// It waits the way the copy does. A download that stops moving is given up after the same quiet
    /// time, and a photo that Photos never started sending is asked for the second way the copy uses,
    /// which hands over the same original bytes. `cancelled` is asked about once a second; when it says
    /// yes the request to Photos is cancelled and a `CancellationError` is thrown, so no download keeps
    /// running after its screen has closed. `read` hears how many bytes arrived, for a progress line.
    static func originalFingerprint(_ id: String, part: Int? = nil, cancelled: () -> Bool = { false },
                                    read: (@Sendable (Int) -> Void)? = nil) throws -> ArchiveFingerprint {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              let resource = file(of: asset, part: part) else { throw ArchiveProofError.originalChanged }
        let sink = ArchiveHasher()
        let activity = ArchiveActivity()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        options.progressHandler = { fraction in activity.progressed(fraction) }
        let completion = DispatchSemaphore(value: 0)
        let manager = PHAssetResourceManager.default()
        let request = manager.requestData(for: resource, options: options) { data in
            activity.received()
            sink.append(data)
            read?(data.count)
        } completionHandler: { error in
            sink.finish(error)
            completion.signal()
        }
        let limit: TimeInterval = asset.mediaType == .video ? 3600 : 600
        switch waitForRead(completion, activity: activity, limit: limit, cancelled: cancelled) {
        case .finished:
            break
        case .cancelled:
            sink.finish(CancellationError())
            manager.cancelDataRequest(request)
            throw CancellationError()
        case let .stalled(receivedSome):
            sink.finish(ArchiveError.iCloudDownload)
            manager.cancelDataRequest(request)
            guard canReadSecondWay(receivedSome: receivedSome, isImage: asset.mediaType == .image, part: part) else {
                throw ArchiveError.iCloudDownload
            }
            let data = try originalImageData(asset, limit: limit, cancelled: cancelled)
            read?(data.count)
            var hash = SHA256()
            hash.update(data: data)
            return fingerprint(hash, bytes: Int64(data.count))
        }
        do {
            return try sink.result()
        } catch let error as NSError where error.domain == PHPhotosErrorDomain {
            throw ArchiveError.iCloudDownload
        }
    }

    /// How a wait for Photos ended.
    enum ReadWait: Equatable { case finished, stalled(receivedSome: Bool), cancelled }

    /// Waits for `done`, looking up every `tick`. Gives up when nothing has arrived and no download
    /// progress was made for the quiet time (shorter before the first byte, as in the copy), or when the
    /// whole read passes `limit`. Stops at once when `cancelled` says so.
    static func waitForRead(_ done: DispatchSemaphore, activity: ArchiveActivity, limit: TimeInterval, tick: TimeInterval = 1,
                            firstQuiet: TimeInterval = ArchiveActivity.firstTryLimit,
                            laterQuiet: TimeInterval = ArchiveActivity.stallLimit, cancelled: () -> Bool) -> ReadWait {
        let started = Date()
        while true {
            if cancelled() { return .cancelled }
            if done.wait(timeout: .now() + tick) == .success { return .finished }
            let quiet = activity.gotData ? laterQuiet : firstQuiet
            if activity.silentFor > quiet || Date().timeIntervalSince(started) > limit {
                return .stalled(receivedSome: activity.gotData)
            }
        }
    }

    /// After a stall: the second way exists only for a photo's original still that sent nothing at all,
    /// exactly as in the copy. Anything else stays unread, and so stays on the iPhone.
    static func canReadSecondWay(receivedSome: Bool, isImage: Bool, part: Int?) -> Bool {
        !receivedSome && isImage && ArchiveParts.allowsImageFallback(part: part)
    }

    /// The second way of reading a photo's unedited original: Photos' image download, held in memory.
    private static func originalImageData(_ asset: PHAsset, limit: TimeInterval, cancelled: () -> Bool) throws -> Data {
        let options = PHImageRequestOptions()
        options.version = .original
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true
        let activity = ArchiveActivity()
        options.progressHandler = { progress, _, _, _ in activity.progressed(progress) }
        let box = ArchiveImageBox()
        let completion = DispatchSemaphore(value: 0)
        let request = PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
            box.set(data, error: info?[PHImageErrorKey] as? Error)
            completion.signal()
        }
        switch waitForRead(completion, activity: activity, limit: limit, firstQuiet: ArchiveActivity.stallLimit, cancelled: cancelled) {
        case .finished:
            break
        case .cancelled:
            PHImageManager.default().cancelImageRequest(request)
            throw CancellationError()
        case .stalled:
            PHImageManager.default().cancelImageRequest(request)
            throw ArchiveError.iCloudDownload
        }
        guard let data = box.data, !data.isEmpty else { throw ArchiveError.iCloudDownload }
        return data
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

    private static func copyPhoto(_ photoID: String, part: Int? = nil, to temporary: URL, wifi: ArchiveWiFi?, flush: Bool) throws -> ArchiveFingerprint {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photoID], options: nil).firstObject,
              let resource = file(of: asset, part: part) else { throw ArchiveError.unsupportedPhoto }
        let id = ArchiveParts.liveKey(photoID, part: part)
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
            guard !receivedSome, asset.mediaType == .image, ArchiveParts.allowsImageFallback(part: part) else {
                throw ArchiveError.iCloudDownload
            }
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
    /// Items already done or given up, whose late progress reports are ignored.
    private var finished: Set<String> = []

    func reset() { lock.lock(); written = 0; sent = 0; downloads = [:]; finished = []; lock.unlock() }
    func wrote(_ count: Int) { lock.lock(); written += Int64(count); lock.unlock() }
    /// Bytes accepted by OneDrive or Dropbox.
    func uploaded(_ count: Int) { lock.lock(); sent += Int64(count); lock.unlock() }

    var uploadedBytes: Int64 {
        lock.lock(); defer { lock.unlock() }
        return sent
    }
    /// Pass nil when the item is done.
    func downloading(_ id: String, _ fraction: Double?) {
        lock.lock(); defer { lock.unlock() }
        if let fraction {
            guard !finished.contains(id) else { return }
            downloads[id] = fraction
        } else {
            downloads[id] = nil
            finished.insert(id)
        }
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
