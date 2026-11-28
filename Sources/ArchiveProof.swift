import CryptoKit
import Foundation
import Photos

/// What an archive copy looked like when it was fully checked, to notice any change afterwards.
struct CopyStamp: Equatable, Sendable {
    let bytes: Int64
    /// Files: the copy's modification date.
    let modified: Date?
    /// Google Drive: Drive's own checksum of what it stores.
    let checksum: String?
}

/// Proof that one archive copy is the exact original. Nothing is deleted after archiving without it.
struct ArchiveProof: Sendable {
    let photoID: String
    let record: ArchivedRecord
    let copy: CopyStamp
    let originalModified: Date?
    /// A Live Photo or edited photo: the same stamp for each of its other files, in the record's order.
    /// Empty for a single-file copy.
    var partCopies: [CopyStamp] = []
    /// A single-file copy: the size Photos reported for the original when it was proven, if it gave one.
    /// Compared with itself right before the delete; never with the copy.
    var originalSize: Int64? = nil
}

/// Why an original stays on the iPhone.
enum ArchiveProofError: LocalizedError, Equatable {
    case notRecorded, copyMissing, copyDiffers, notUploaded, notConfirmable, originalChanged, changedSinceCheck, editChanged

    var errorDescription: String? {
        switch self {
        case .notRecorded: "Its copy isn't recorded in Get back."
        case .copyMissing: "Its copy couldn't be found."
        case .copyDiffers: "Its copy doesn't match the original."
        case .notUploaded: "Its copy hasn't finished uploading to iCloud yet."
        case .notConfirmable: "Its copy is on this \(Device.name), or in a cloud folder that can't prove it finished uploading."
        case .originalChanged: "The original changed after it was copied."
        case .changedSinceCheck: "Something changed after the check."
        case .editChanged: "It was edited after it was copied, so its copy doesn't hold the latest edit. Copy it again."
        }
    }
}

/// Checks archive copies before originals may be deleted. Each copy was checked while it was made: the
/// original was fingerprinted as it streamed, and the destination had to hold exactly as many bytes.
/// `prove` makes sure the copy is still there, off this iPhone, at exactly the size recorded (on Google
/// Drive also Drive's own SHA-256), and that the original hasn't changed since. `confirm` repeats that
/// right before the delete. Any error means the original stays. (Owner, 2026-11-22: size to the byte,
/// not a full read-back, so freeing space stays fast. Owner, 2026-11-24: the original in Photos is read
/// again in full, so anything edited after it was copied stays.)
enum ArchiveProver {
    /// Runs a blocking read of originals off the main thread. If the task asking is cancelled (the screen
    /// closed), the read is told, cancels its request to Photos and throws.
    private static func reading<T: Sendable>(_ work: @escaping @Sendable (_ cancelled: @escaping @Sendable () -> Bool) throws -> T) async throws -> T {
        let gate = ArchiveGate()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) { try work { !gate.isOpen } }.value
        } onCancel: {
            gate.close()
        }
    }

    /// `copies` hears how much of the copies on a drive, folder or home server has been read back.
    static func prove(photoID: String, record: ArchivedRecord?, wifi: ArchiveWiFi, progress: ProofProgress? = nil,
                      copies: ProofProgress? = nil) async throws -> ArchiveProof {
        guard let record else { throw ArchiveProofError.notRecorded }
        let modified = try originalModificationDate(photoID)
        // A copy on a drive, folder or server is read back in full once (1.0.2, A3); cloud copies are
        // matched by the service's own checksum, as before.
        let readBack = copies ?? ProofProgress()
        let stamp = try await currentStamp(record, wifi: wifi, readBack: readBack)
        guard record.hasParts else {
            // A single file (owner, 2026-11-24): the original must still be that one file and nothing
            // more, and reading it again in full must give the recorded fingerprint. A photo or video
            // edited after it was copied fails here, so its edit is never deleted with it.
            let size = try await reading { cancelled in
                try sameOriginal(photoID, as: record, readInFull: true, cancelled: cancelled, progress: progress)
            }
            return ArchiveProof(photoID: photoID, record: record, copy: stamp, originalModified: modified, originalSize: size)
        }
        // A Live Photo or edited photo: the original must still be made of the same kinds of files, its
        // edit must still be byte for byte the one that was copied, and every one of the copies must pass
        // the same check as the first.
        try await reading { cancelled in try sameParts(photoID, as: record, cancelled: cancelled, progress: progress) }
        var others: [CopyStamp] = []
        for file in record.files.dropFirst() { others.append(try await currentStamp(file, wifi: wifi, readBack: readBack)) }
        return ArchiveProof(photoID: photoID, record: record, copy: stamp, originalModified: modified, partCopies: others)
    }

    static func confirm(_ proof: ArchiveProof, wifi: ArchiveWiFi) async throws {
        guard try originalModificationDate(proof.photoID) == proof.originalModified else {
            throw ArchiveProofError.originalChanged
        }
        guard try await currentStamp(proof.record, wifi: wifi) == proof.copy else { throw ArchiveProofError.changedSinceCheck }
        let photoID = proof.photoID, record = proof.record
        guard proof.record.hasParts || !proof.partCopies.isEmpty else {
            // A single file, once more: still one file of the same kind and, as Photos reports it, the
            // same size as when it was proven. It was read in full moments ago by `prove`; reading it
            // again here would download an iCloud original once more after the person's OK, and any
            // edit since then changes its files, its size or its modification date, checked above.
            let size = try await reading { cancelled in
                try sameOriginal(photoID, as: record, readInFull: false, cancelled: cancelled, progress: nil)
            }
            guard unchangedSize(size, since: proof.originalSize) else { throw ArchiveProofError.editChanged }
            return
        }
        try await reading { cancelled in try sameParts(photoID, as: record, cancelled: cancelled, progress: nil) }
        let files = Array(proof.record.files.dropFirst())
        guard partsProven(files.count, stamps: proof.partCopies.count) else { throw ArchiveProofError.changedSinceCheck }
        for (file, stamp) in zip(files, proof.partCopies) {
            guard try await currentStamp(file, wifi: wifi) == stamp else { throw ArchiveProofError.changedSinceCheck }
        }
    }

    /// The original of a single-file copy, as it is in Photos now. Returns the size Photos reports for it.
    /// With `readInFull` (the check) the original is read again in full; without it (right before the
    /// delete) only its files and reported size are looked at. Reads from Photos, so it blocks: call it
    /// off the main thread.
    static func sameOriginal(_ id: String, as record: ArchivedRecord, readInFull: Bool, cancelled: @escaping () -> Bool = { false },
                             progress: ProofProgress? = nil) throws -> Int64? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw ArchiveProofError.originalChanged
        }
        let resources = PHAssetResource.assetResources(for: asset)
        var current: (() throws -> ArchiveFingerprint)? = nil
        if readInFull {
            current = { try VerifiedArchive.originalFingerprint(id, cancelled: cancelled, read: { progress?.add($0) }) }
        }
        // Photo or video comes from the item itself, not from the copy's file name.
        let kind = asset.mediaType == .video ? PHAssetResourceType.video.rawValue : PHAssetResourceType.photo.rawValue
        try sameSingleFile(types: resources.map { $0.type.rawValue }, kind: kind, as: record, current: current)
        // The same rule the copy itself was made under: one original file, not a Live Photo.
        guard VerifiedArchive.original(for: asset) != nil else { throw ArchiveProofError.editChanged }
        return DuplicateScanner.reportedSize(of: resources)
    }

    /// A single-file copy still stands for the whole item only while the original is exactly one file of
    /// the kind that was copied (an edit, a crop or a trim adds files beside it), and, when it is read
    /// again by `current`, only while its bytes are the ones in the record. A record with no usable
    /// fingerprint can never match, so its original stays.
    /// `kind` is the one kind of file a single-file copy of this item is made from: a photo or a video.
    static func sameSingleFile(types: [Int], kind: Int, as record: ArchivedRecord, current: (() throws -> ArchiveFingerprint)?) throws {
        guard types == [kind] else { throw ArchiveProofError.editChanged }
        guard let current else { return }
        guard !record.digest.isEmpty, try current() == fingerprint(of: record) else { throw ArchiveProofError.editChanged }
    }

    /// The size Photos reports now must be what it reported when the original was proven. Both unknown
    /// is the same; known then and unknown now, or the other way round, is not.
    static func unchangedSize(_ now: Int64?, since proven: Int64?) -> Bool { now == proven }

    /// Every other file of the item needs its own stamp: one short, or one extra, proves nothing.
    static func partsProven(_ files: Int, stamps: Int) -> Bool { files > 0 && files == stamps }

    /// Two checks on the original of a Live Photo or edited photo, as it is in Photos now.
    /// First, it must be made of the same kinds of files that were archived: a first edit, or a revert,
    /// changes the kinds. Second, because a later edit keeps the kinds and changes only the bytes, its
    /// edit files (instructions, edited picture, edited video) are read again in full and must match the
    /// fingerprints recorded when they were copied. The original still and video are not re-read here;
    /// Photos never rewrites them. Reads the files from Photos, so it blocks: call it off the main thread.
    static func sameParts(_ id: String, as record: ArchivedRecord, cancelled: () -> Bool = { false },
                          progress: ProofProgress? = nil) throws {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              let files = VerifiedArchive.plan(for: asset),
              files.map({ $0.type.rawValue }) == record.partTypes else { throw ArchiveProofError.originalChanged }
        try sameEdit(as: record) {
            try VerifiedArchive.originalFingerprint(id, part: $0, cancelled: cancelled, read: { progress?.add($0) })
        }
    }

    /// The edit files, read now by `current`, must be byte for byte the ones in the record.
    static func sameEdit(as record: ArchivedRecord, current: (Int) throws -> ArchiveFingerprint) throws {
        let copied = zip(record.partTypes, record.files).map { (type: $0, fingerprint: fingerprint(of: $1)) }
        guard try ArchiveParts.editUnchanged(copied, current: current) else { throw ArchiveProofError.editChanged }
    }

    /// The copy as the destination describes it now. It must exist, be off this iPhone and be exactly the
    /// recorded size; a Drive copy must also carry the recorded SHA-256 when Drive reports one.
    /// With `readBack` (the check before removal), a copy on a drive, folder or home server is also read
    /// back in full, without the cache, and must give the fingerprint taken when it was archived, unless
    /// it already did since it last changed (`ReadBackLedger`). Without it (right before the delete),
    /// size only, as before.
    private static func currentStamp(_ record: ArchivedRecord, wifi: ArchiveWiFi, readBack: ProofProgress? = nil) async throws -> CopyStamp {
        if let service = record.cloud, let fileID = record.driveFileID {
            let account = await CloudAccount.shared(service)
            let token = try await account.accessToken()
            return try stamp(of: try await CloudArchive.stored(fileID, in: service, token: token), for: record, in: service)
        }
        if let fileID = record.driveFileID {
            let token = try await GoogleDriveAccount.shared.accessToken()
            return try Self.stamp(of: try await GoogleDriveClient.storedFile(fileID, token: token), for: record)
        }
        let folder = try Self.folder(of: record)
        let name = record.name
        let wifiCheck: ArchiveWiFi? = record.viaHomeServer ? wifi : nil
        let expected = fingerprint(of: record)
        let stamp = try await Task.detached(priority: .userInitiated) {
            let quick = try VerifiedArchive.copyStamp(named: name, in: folder, wifi: wifiCheck)
            guard quick.bytes == record.bytes else { throw ArchiveProofError.copyDiffers }
            guard let readBack, !ReadBackLedger.readBack(record, stamp: quick) else { return quick }
            guard !record.digest.isEmpty else { throw ArchiveProofError.copyDiffers }
            let full = try VerifiedArchive.checkCopy(named: name, in: folder, expected: expected, wifi: wifiCheck,
                                                     read: { readBack.add($0) })
            ReadBackLedger.note(record, stamp: full)
            return full
        }.value
        guard stamp.bytes == record.bytes else { throw ArchiveProofError.copyDiffers }
        return stamp
    }

    /// Drive must still hold the file, outside the bin, with the same size and, when Drive gives one,
    /// the same SHA-256 checksum.
    static func stamp(of file: GoogleDriveClient.StoredFile, for record: ArchivedRecord) throws -> CopyStamp {
        guard file.trashed == false else { throw ArchiveProofError.copyMissing }
        guard let size = file.size.flatMap(Int64.init), size == record.bytes else { throw ArchiveProofError.copyDiffers }
        if let checksum = file.sha256Checksum, checksum.lowercased() != record.digest.lowercased() {
            throw ArchiveProofError.copyDiffers
        }
        return CopyStamp(bytes: size, modified: nil, checksum: file.sha256Checksum ?? file.md5Checksum)
    }

    /// OneDrive or Dropbox must still hold the file at exactly the recorded size, with the same
    /// fingerprint the service gave when it was archived.
    static func stamp(of file: CloudStoredFile, for record: ArchivedRecord, in service: CloudService) throws -> CopyStamp {
        guard file.bytes == record.bytes else { throw ArchiveProofError.copyDiffers }
        guard let hash = file.hash, let recorded = record.cloudHash, CloudArchive.sameHash(hash, recorded, service: service) else {
            throw ArchiveProofError.copyDiffers
        }
        return CopyStamp(bytes: file.bytes, modified: nil, checksum: hash)
    }

    /// Whether every file of this copy is still where it was saved, at exactly the recorded size. Only
    /// what the destination says about each file is read, never its contents: a metadata call for
    /// Google Drive, OneDrive and Dropbox (the same one `prove` makes), and the file's size for a drive,
    /// folder or home server. Anything that can't be reached, or doesn't answer within `timeout`
    /// seconds, counts as not there.
    static func copyStillThere(_ record: ArchivedRecord, wifi: ArchiveWiFi, timeout: TimeInterval = ArchiveDeadline.perCopy) async -> Bool {
        let answer = await ArchiveDeadline.within(timeout) { () async throws -> Bool in
            for file in record.files { try await presentCopy(file, wifi: wifi) }
            return true
        }
        return answer ?? false
    }

    private static func presentCopy(_ record: ArchivedRecord, wifi: ArchiveWiFi) async throws {
        if record.cloud != nil || record.driveFileID != nil {
            _ = try await currentStamp(record, wifi: wifi)
            return
        }
        let folder = try Self.folder(of: record)
        let name = record.name
        let wifiCheck: ArchiveWiFi? = record.viaHomeServer ? wifi : nil
        let size = try await Task.detached(priority: .userInitiated) {
            try VerifiedArchive.presentSize(named: name, in: folder, wifi: wifiCheck)
        }.value
        guard size == record.bytes else { throw ArchiveProofError.copyMissing }
    }

    static func fingerprint(of record: ArchivedRecord) -> ArchiveFingerprint {
        ArchiveFingerprint(bytes: record.bytes, digest: record.digest.lowercased())
    }

    private static func folder(of record: ArchivedRecord) throws -> URL {
        var stale = false
        guard let bookmark = record.folderBookmark,
              let folder = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else {
            throw ArchiveProofError.copyMissing
        }
        return folder
    }

    private static func originalModificationDate(_ id: String) throws -> Date? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else {
            throw ArchiveProofError.originalChanged
        }
        return asset.modificationDate
    }
}

/// How much of the originals the check has read so far, for the progress line. Safe from any thread.
final class ProofProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var read: Int64 = 0
    func add(_ count: Int) { lock.lock(); read += Int64(count); lock.unlock() }
    func reset() { lock.lock(); read = 0; lock.unlock() }
    var bytes: Int64 { lock.lock(); defer { lock.unlock() }; return read }
}

/// Reads a whole file back from Google Drive and hashes it, without storing it on the iPhone.
final class DriveReadBack: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private var hasher = SHA256()
    private var bytes: Int64 = 0
    private var failure: Error?
    private var continuation: CheckedContinuation<ArchiveFingerprint, Error>?

    private init(_ continuation: CheckedContinuation<ArchiveFingerprint, Error>) {
        self.continuation = continuation
    }

    static func fingerprint(_ fileID: String, token: String) async throws -> ArchiveFingerprint {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)?alt=media")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 120
        let finalRequest = request
        return try await withCheckedThrowingContinuation { continuation in
            let session = URLSession(configuration: .ephemeral, delegate: DriveReadBack(continuation), delegateQueue: nil)
            session.dataTask(with: finalRequest).resume()
            session.finishTasksAndInvalidate()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 200 {
            completionHandler(.allow)
        } else {
            failure = GoogleDriveError.server(status)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        hasher.update(data: data)
        bytes += Int64(data.count)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let problem = failure ?? error {
            continuation?.resume(throwing: problem)
        } else {
            continuation?.resume(returning: ArchiveFingerprint(
                bytes: bytes, digest: hasher.finalize().map { String(format: "%02x", $0) }.joined()))
        }
        continuation = nil
    }
}

extension Result where Failure == Error {
    init(awaiting work: () async throws -> Success) async {
        do { self = .success(try await work()) } catch { self = .failure(error) }
    }
}
