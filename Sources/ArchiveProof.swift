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
        case .notConfirmable: "Its copy is on this iPhone, or in a cloud folder that can't prove it finished uploading."
        case .originalChanged: "The original changed after it was copied."
        case .changedSinceCheck: "Something changed after the check."
        }
    }
}

/// Checks archive copies before originals may be deleted. Every copy was already checked while it was
/// made. `prove` reads the whole copy back from the destination and the whole original from Photos, and
/// both must match the fingerprint taken when archiving. `confirm` runs right before the delete and
/// makes sure nothing changed since `prove`. Any error means the original stays.
enum ArchiveProver {
    static func prove(photoID: String, record: ArchivedRecord?, wifi: ArchiveWiFi) async throws -> ArchiveProof {
        guard let record else { throw ArchiveProofError.notRecorded }
        let modified = try originalModificationDate(photoID)
        let stamp = try await checkCopy(record, wifi: wifi)
        let original = try await Task.detached(priority: .userInitiated) {
            try VerifiedArchive.originalFingerprint(photoID)
        }.value
        guard original == fingerprint(of: record) else { throw ArchiveProofError.originalChanged }
        return ArchiveProof(photoID: photoID, record: record, copy: stamp, originalModified: modified)
    }

    static func confirm(_ proof: ArchiveProof, wifi: ArchiveWiFi) async throws {
        guard try originalModificationDate(proof.photoID) == proof.originalModified else {
            throw ArchiveProofError.originalChanged
        }
        let now: CopyStamp
        if let fileID = proof.record.driveFileID {
            let token = try await GoogleDriveAccount.shared.accessToken()
            now = try Self.stamp(of: try await GoogleDriveClient.storedFile(fileID, token: token), for: proof.record)
        } else {
            let folder = try Self.folder(of: proof.record)
            let name = proof.record.name
            let wifiCheck: ArchiveWiFi? = proof.record.viaHomeServer ? wifi : nil
            now = try await Task.detached(priority: .userInitiated) {
                try VerifiedArchive.copyStamp(named: name, in: folder, wifi: wifiCheck)
            }.value
        }
        guard now == proof.copy else { throw ArchiveProofError.changedSinceCheck }
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

    static func fingerprint(of record: ArchivedRecord) -> ArchiveFingerprint {
        ArchiveFingerprint(bytes: record.bytes, digest: record.digest.lowercased())
    }

    private static func checkCopy(_ record: ArchivedRecord, wifi: ArchiveWiFi) async throws -> CopyStamp {
        if let fileID = record.driveFileID {
            let token = try await GoogleDriveAccount.shared.accessToken()
            let stamp = try Self.stamp(of: try await GoogleDriveClient.storedFile(fileID, token: token), for: record)
            // Drive's own checksum matches; also read the file back and compare every byte.
            guard try await DriveReadBack.fingerprint(fileID, token: token) == fingerprint(of: record) else {
                throw ArchiveProofError.copyDiffers
            }
            return stamp
        }
        let folder = try Self.folder(of: record)
        let name = record.name
        let expected = fingerprint(of: record)
        let wifiCheck: ArchiveWiFi? = record.viaHomeServer ? wifi : nil
        return try await Task.detached(priority: .userInitiated) {
            try VerifiedArchive.checkCopy(named: name, in: folder, expected: expected, wifi: wifiCheck)
        }.value
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
