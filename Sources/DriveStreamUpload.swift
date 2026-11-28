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

    /// What the upload session answered: the HTTP status, the body, and on a 308 the Range header,
    /// which says how much of the file Drive holds so far.
    struct Reply {
        let status: Int
        let body: Data
        var range: String? = nil
    }

    /// Sends one piece to the upload session (or, with an empty body and `bytes */...`, asks how much
    /// Drive holds) and returns its answer.
    typealias Transport = @Sendable (_ body: Data, _ contentRange: String) throws -> Reply

    /// What an answer from the upload session means.
    enum Step: Equatable {
        /// Drive has the whole file; the body describes it.
        case finished
        /// Drive holds this many bytes of the file so far.
        case holds(Int64)
    }

    private let transport: Transport
    private let pause: @Sendable (Int) -> Void
    private let lock = NSLock()
    private var buffer = Data()
    private var sent: Int64 = 0
    private var sha = SHA256()
    private var md5 = Insecure.MD5()
    private var failure: Error?
    private var uploaded: Uploaded?

    /// `pause` waits before retry number 1, 2 and so on; tests pass one that doesn't wait.
    init(transport: @escaping Transport, pause: @escaping @Sendable (Int) -> Void = { UploadRetry.wait($0) }) {
        self.transport = transport
        self.pause = pause
    }

    /// How many bytes a 308's Range header says Drive holds: "bytes=0-1048575" is 1,048,576. Nil when
    /// the header can't be read. (No header at all means Drive holds nothing yet.)
    static func held(range: String) -> Int64? {
        let text = range.trimmingCharacters(in: .whitespaces)
        guard text.hasPrefix("bytes=") else { return nil }
        let bounds = text.dropFirst("bytes=".count).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, Int64(bounds[0]) == 0, let last = Int64(bounds[1]), last >= 0 else { return nil }
        return last + 1
    }

    /// Reads one answer. Anything but "finished" or "keep going" throws, so it can be retried or reported.
    static func step(status: Int, range: String?) throws -> Step {
        switch status {
        case 200, 201: return .finished
        case 308:
            guard let range else { return .holds(0) }
            guard let count = Self.held(range: range) else { throw GoogleDriveError.server(status) }
            return .holds(count)
        default: throw GoogleDriveError.server(status)
        }
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

    /// Sends one piece. After each answer Drive says how much of the file it holds, and whatever it
    /// didn't keep is sent again from there. A dropped connection or a busy server is retried a few
    /// times, each time after asking Drive how much it already has; then the item fails as before.
    private func send(_ piece: Data, last: Bool) {
        let start = sent
        let end = start + Int64(piece.count)
        let total: Int64? = last ? end : nil
        var held = start
        var tries = 0
        var asking = false
        do {
            while true {
                let rest = asking ? Data() : Data(piece[(piece.startIndex + Int(held - start))...])
                let range = Self.contentRange(start: held, count: rest.count, total: total)
                let reply: Reply
                let step: Step
                do {
                    reply = try transport(rest, range)
                    step = try Self.step(status: reply.status, range: reply.range)
                } catch {
                    guard tries < UploadRetry.attempts, UploadRetry.retryable(error) else { throw error }
                    tries += 1
                    pause(tries)
                    asking = true
                    continue
                }
                switch step {
                case .finished:
                    // Only the last piece can finish the file.
                    guard last else { throw GoogleDriveError.server(reply.status) }
                    uploaded = try JSONDecoder().decode(Uploaded.self, from: reply.body)
                    sent = end
                    return
                case let .holds(count):
                    // Drive can't hold bytes it was never sent, and bytes before this piece are gone from here.
                    guard count >= start, count <= end else { throw GoogleDriveError.server(reply.status) }
                    let moved = asking || count > held
                    held = count
                    asking = false
                    if !last, held == end {
                        sent = end
                        return
                    }
                    if !moved {
                        guard tries < UploadRetry.attempts else { throw GoogleDriveError.server(reply.status) }
                        tries += 1
                        pause(tries)
                    }
                }
            }
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
        // An edit made while the files were going up would leave parts of two different edits.
        try ArchiveParts.requireSameEdit(files, uploads.map { $0.fingerprint })
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
            var held: String?
            let reply = try syncSend(request, body: body) { held = $0.value(forHTTPHeaderField: "Range") }
            return DriveStreamUpload.Reply(status: reply.status, body: reply.body, range: held)
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
