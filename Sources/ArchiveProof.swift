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
}

/// Why an original stays on the iPhone.
enum ArchiveProofError: LocalizedError, Equatable {
    case notRecorded, copyMissing, copyDiffers, notUploaded, notConfirmable, originalChanged, changedSinceCheck

    var errorDescription: String? {
        switch self {
        case .notRecorded: "Its copy isn't recorded in Get back."
        case .copyMissing: "Its copy couldn't be found."
        case .copyDiffers: "Its copy doesn't match the original."
        case .notUploaded: "Its copy hasn't finished uploading to iCloud yet."
        case .notConfirmable: "Its copy is on this \(Device.name), or in a cloud folder that can't prove it finished uploading."
        case .originalChanged: "The original changed after it was copied."
        case .changedSinceCheck: "Something changed after the check."
        }
    }
}

/// Checks archive copies before originals may be deleted. Each copy was checked while it was made: the
/// original was fingerprinted as it streamed, and the destination had to hold exactly as many bytes.
/// `prove` makes sure the copy is still there, off this iPhone, at exactly the size recorded (on Google
/// Drive also Drive's own SHA-256), and that the original hasn't changed since. `confirm` repeats that
/// right before the delete. Any error means the original stays. (Owner, 2026-11-22: size to the byte,
/// not a full read-back, so freeing space stays fast.)
enum ArchiveProver {
    static func prove(photoID: String, record: ArchivedRecord?, wifi: ArchiveWiFi) async throws -> ArchiveProof {
        guard let record else { throw ArchiveProofError.notRecorded }
        let modified = try originalModificationDate(photoID)
        let stamp = try await currentStamp(record, wifi: wifi)
        guard record.hasParts else {
            return ArchiveProof(photoID: photoID, record: record, copy: stamp, originalModified: modified)
        }
        // A Live Photo or edited photo: the original must still be made of exactly the files that were
        // copied, and every one of those copies must pass the same check as the first.
        try sameParts(photoID, as: record)
        var others: [CopyStamp] = []
        for file in record.files.dropFirst() { others.append(try await currentStamp(file, wifi: wifi)) }
        return ArchiveProof(photoID: photoID, record: record, copy: stamp, originalModified: modified, partCopies: others)
    }

    static func confirm(_ proof: ArchiveProof, wifi: ArchiveWiFi) async throws {
        guard try originalModificationDate(proof.photoID) == proof.originalModified else {
            throw ArchiveProofError.originalChanged
        }
        guard try await currentStamp(proof.record, wifi: wifi) == proof.copy else { throw ArchiveProofError.changedSinceCheck }
        guard proof.record.hasParts || !proof.partCopies.isEmpty else { return }
        try sameParts(proof.photoID, as: proof.record)
        let files = Array(proof.record.files.dropFirst())
        guard partsProven(files.count, stamps: proof.partCopies.count) else { throw ArchiveProofError.changedSinceCheck }
        for (file, stamp) in zip(files, proof.partCopies) {
            guard try await currentStamp(file, wifi: wifi) == stamp else { throw ArchiveProofError.changedSinceCheck }
        }
    }

    /// Every other file of the item needs its own stamp: one short, or one extra, proves nothing.
    static func partsProven(_ files: Int, stamps: Int) -> Bool { files > 0 && files == stamps }

    /// The original in Photos must still be made of exactly the files that were archived. An edit made
    /// (or undone) after the copy changes them, and then the copy is no longer the whole item.
    private static func sameParts(_ id: String, as record: ArchivedRecord) throws {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
              let files = VerifiedArchive.plan(for: asset),
              files.map({ $0.type.rawValue }) == record.partTypes else { throw ArchiveProofError.originalChanged }
    }

    /// The copy as the destination describes it now. It must exist, be off this iPhone and be exactly the
    /// recorded size; a Drive copy must also carry the recorded SHA-256 when Drive reports one.
    private static func currentStamp(_ record: ArchivedRecord, wifi: ArchiveWiFi) async throws -> CopyStamp {
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
        let stamp = try await Task.detached(priority: .userInitiated) {
            try VerifiedArchive.copyStamp(named: name, in: folder, wifi: wifiCheck)
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
