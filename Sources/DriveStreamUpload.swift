import CryptoKit
import Foundation
import Photos

/// Streams one archive item into Google Drive in 8 MB pieces as Photos (or Files) hands them over,
/// so no full copy of the item ever needs room on the iPhone. Every byte is hashed on the way and the
/// result is checked against Drive's own checksum of what it stored.
final class DriveStreamUpload: @unchecked Sendable {
    /// Google requires pieces in multiples of 256 KiB, except the last.
    static let pieceSize = 32 * 256 * 1024

    struct Uploaded: Decodable {
        let id: String
        let sha256Checksum: String?
        let md5Checksum: String?
    }

    /// Sends one piece to the upload session and returns the HTTP status and body.
    typealias Transport = @Sendable (_ body: Data, _ contentRange: String) throws -> (status: Int, body: Data)

    private let transport: Transport
    private let lock = NSLock()
    private var buffer = Data()
    private var sent: Int64 = 0
    private var sha = SHA256()
    private var md5 = Insecure.MD5()
    private var failure: Error?
    private var uploaded: Uploaded?

    init(transport: @escaping Transport) {
        self.transport = transport
    }

    /// The Content-Range header for a piece. The total is unknown ("*") until the last piece.
    static func contentRange(start: Int64, count: Int, total: Int64?) -> String {
        let totalText = total.map(String.init) ?? "*"
        guard count > 0 else { return "bytes */\(totalText)" }
        return "bytes \(start)-\(start + Int64(count) - 1)/\(totalText)"
    }

    /// Adds downloaded bytes; full pieces are sent straight away. Blocking here also slows the
    /// download to the upload speed, so memory stays at about one piece.
    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil else { return }
        sha.update(data: data)
        md5.update(data: data)
        buffer.append(data)
        while buffer.count >= Self.pieceSize, failure == nil {
            let piece = buffer.prefix(Self.pieceSize)
            send(Data(piece), last: false)
            buffer.removeFirst(Self.pieceSize)
        }
    }

    func fail(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        failure = failure ?? error
    }

    /// Sends what's left as the last piece and returns the Drive file and the original's fingerprint.
    func finish() throws -> (file: Uploaded, fingerprint: ArchiveFingerprint) {
        lock.lock()
        defer { lock.unlock() }
        if failure == nil { send(buffer, last: true) }
        if let failure { throw failure }
        guard let uploaded else { throw GoogleDriveError.server(0) }
        let digest = sha.finalize().map { String(format: "%02x", $0) }.joined()
        let md5Hex = md5.finalize().map { String(format: "%02x", $0) }.joined()
        if let checksum = uploaded.sha256Checksum {
            guard checksum.lowercased() == digest else { throw GoogleDriveError.verification }
        } else if let checksum = uploaded.md5Checksum {
            guard checksum.lowercased() == md5Hex else { throw GoogleDriveError.verification }
        } else {
            throw GoogleDriveError.verification
        }
        return (uploaded, ArchiveFingerprint(bytes: sent, digest: digest))
    }

    private func send(_ piece: Data, last: Bool) {
        let range = Self.contentRange(start: sent, count: piece.count, total: last ? sent + Int64(piece.count) : nil)
        do {
            let response = try transport(piece, range)
            if last {
                guard (200...201).contains(response.status) else { throw GoogleDriveError.server(response.status) }
                uploaded = try JSONDecoder().decode(Uploaded.self, from: response.body)
            } else {
                // 308 means "keep going".
                guard response.status == 308 else { throw GoogleDriveError.server(response.status) }
            }
            sent += Int64(piece.count)
        } catch {
            failure = error
        }
    }
}

extension GoogleDriveClient {
    /// Streams every file of an item to Google Drive. A single-file item goes exactly the way it always
    /// has. A Live Photo or edited photo is streamed file by file, each checked against Drive's own
    /// checksum like a single file, and counts only when all of them are stored.
    static func streamUploadEvery(_ item: ArchiveItem, folderID: String, token: String) throws
        -> (fileID: String, fingerprint: ArchiveFingerprint, parts: [ArchivedPart]) {
        guard let files = try ArchiveParts.files(of: item) else {
            let single = try streamUpload(item, folderID: folderID, token: token)
            return (single.fileID, single.fingerprint, [])
        }
        let uploads = try ArchiveParts.every(files) { try streamUpload($0, folderID: folderID, token: token) }
        let stored = zip(files, uploads).map { StoredPart(name: $0.name, fingerprint: $1.fingerprint, fileID: $1.fileID) }
        return (uploads[0].fileID, uploads[0].fingerprint, ArchiveParts.parts(files, stored))
    }

    /// Archives one item to Google Drive by streaming it, with no local copy. Runs off the main thread.
    static func streamUpload(_ item: ArchiveItem, folderID: String, token: String) throws -> (fileID: String, fingerprint: ArchiveFingerprint) {
        let session = try startSession(name: item.name, folderID: folderID, token: token)
        let upload = DriveStreamUpload { body, range in
            var request = URLRequest(url: session)
            request.httpMethod = "PUT"
            request.timeoutInterval = 600
            request.setValue(range, forHTTPHeaderField: "Content-Range")
            return try syncSend(request, body: body)
        }
        switch item.source {
        case let .photo(id, expected):
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject,
                  let resource = VerifiedArchive.file(of: asset, part: item.part) else { throw ArchiveError.unsupportedPhoto }
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            let done = DispatchSemaphore(value: 0)
            let manager = PHAssetResourceManager.default()
            let request = manager.requestData(for: resource, options: options) { data in
                upload.append(data)
            } completionHandler: { error in
                if let error {
                    upload.fail((error as NSError).domain == PHPhotosErrorDomain ? ArchiveError.iCloudDownload : error)
                }
                done.signal()
            }
            if done.wait(timeout: .now() + (asset.mediaType == .video ? .seconds(3600) : .seconds(600))) == .timedOut {
                manager.cancelDataRequest(request)
                upload.fail(ArchiveError.unavailable)
            }
            let result = try upload.finish()
            if let expected, result.fingerprint != ArchiveFingerprint(bytes: expected.bytes, digest: expected.digest) {
                throw ArchiveError.verification
            }
            return (result.file.id, result.fingerprint)
        case let .file(url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { upload.append(chunk) }
            let result = try upload.finish()
            return (result.file.id, result.fingerprint)
        }
    }

    /// Opens a resumable upload for a new file in the archive folder. Drive never overwrites:
    /// a file with the same name is added alongside.
    private static func startSession(name: String, folderID: String, token: String) throws -> URL {
        var start = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&fields=id,sha256Checksum,md5Checksum")!)
        start.httpMethod = "POST"
        start.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        start.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let body = try JSONSerialization.data(withJSONObject: ["name": name, "parents": [folderID]])
        var location: String?
        let response = try syncSend(start, body: body) { location = $0.value(forHTTPHeaderField: "Location") }
        guard response.status == 200, let location, let url = URL(string: location) else {
            throw GoogleDriveError.server(response.status)
        }
        return url
    }

    /// A blocking request, used inside the streaming callbacks so uploads pace the download.
    private static func syncSend(_ request: URLRequest, body: Data,
                                 headers: ((HTTPURLResponse) -> Void)? = nil) throws -> (status: Int, body: Data) {
        let done = DispatchSemaphore(value: 0)
        var result: Result<(Int, Data), Error> = .failure(GoogleDriveError.server(0))
        let task = URLSession.shared.uploadTask(with: request, from: body) { data, response, error in
            if let error { result = .failure(error) }
            else if let http = response as? HTTPURLResponse {
                headers?(http)
                result = .success((http.statusCode, data ?? Data()))
            }
            done.signal()
        }
        task.resume()
        done.wait()
        let (status, data) = try result.get()
        return (status, data)
    }
}
