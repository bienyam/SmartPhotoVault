import CryptoKit
import Foundation
import Photos

/// Collects an item's bytes as they arrive and sends them on in pieces, so no full copy ever needs
/// room on the iPhone. Every byte is fingerprinted on the way (SHA-256, plus OneDrive's and
/// Dropbox's own fingerprints) so the stored copy can be matched before it counts.
final class CloudPieces: @unchecked Sendable {
    /// OneDrive needs pieces in multiples of 320 KiB, except the last; Dropbox takes any size.
    static let pieceSize = CloudArchive.pieceSize

    /// Sends one piece starting at `offset`. Blocking here paces the download to the upload.
    typealias Send = (_ piece: Data, _ offset: Int64) throws -> Void

    let activity = ArchiveActivity()
    private let lock = NSLock()
    private let send: Send
    private var buffer = Data()
    private var sent: Int64 = 0
    private var failure: Error?
    private var sha = SHA256()
    private var quick = QuickXorHash()
    private var box = DropboxContentHash()

    init(send: @escaping Send) { self.send = send }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard failure == nil else { return }
        activity.received()
        sha.update(data: data)
        quick.update(data)
        box.update(data)
        buffer.append(data)
        while buffer.count >= Self.pieceSize, failure == nil {
            ship(Data(buffer.prefix(Self.pieceSize)))
            buffer.removeFirst(Self.pieceSize)
        }
    }

    func fail(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        failure = failure ?? error
    }

    var failed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return failure != nil
    }

    /// Sends what's left and returns the original's fingerprint and the services' fingerprints.
    func finish() throws -> (fingerprint: ArchiveFingerprint, quickXor: String, dropbox: String) {
        lock.lock()
        defer { lock.unlock() }
        if failure == nil, !buffer.isEmpty { ship(buffer) }
        buffer = Data()
        if let failure { throw failure }
        let digest = sha.finalize().map { String(format: "%02x", $0) }.joined()
        return (ArchiveFingerprint(bytes: sent, digest: digest), quick.finalize(), box.finalize())
    }

    private func ship(_ piece: Data) {
        do {
            try send(piece, sent)
            sent += Int64(piece.count)
            ArchiveLive.shared.uploaded(piece.count)
            activity.received()
        } catch {
            failure = error
        }
    }
}

/// Lets a cancelled Photos request's late callbacks be ignored.
final class ArchiveGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    func close() { lock.lock(); open = false; lock.unlock() }
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return open }
}

enum CloudStream {
    struct Stored: Decodable {
        let id: String
        let name: String?
        let size: Int64?
    }

    /// The size of the item before it is read, which OneDrive needs up front.
    static func knownSize(of item: ArchiveItem) -> Int64? {
        switch item.source {
        case let .photo(_, expected): return item.size ?? expected?.bytes
        case let .file(url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        }
    }

    /// Feeds the item's bytes into `pieces` as Photos or Files hands them over. A photo that Photos
    /// never starts sending is asked for a second way; anything stuck gives up so the run moves on.
    static func feed(_ item: ArchiveItem, into pieces: CloudPieces) {
        switch item.source {
        case let .file(url):
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                while !pieces.failed, let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { pieces.append(chunk) }
            } catch {
                pieces.fail(error)
            }
        case let .photo(photoID, _):
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [photoID], options: nil).firstObject,
                  let resource = VerifiedArchive.file(of: asset, part: item.part) else {
                pieces.fail(ArchiveError.unsupportedPhoto)
                return
            }
            let id = ArchiveParts.liveKey(photoID, part: item.part)
            defer { ArchiveLive.shared.downloading(id, nil) }
            let gate = ArchiveGate()
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            options.progressHandler = { fraction in
                pieces.activity.progressed(fraction)
                ArchiveLive.shared.downloading(id, fraction)
            }
            let done = DispatchSemaphore(value: 0)
            let manager = PHAssetResourceManager.default()
            let request = manager.requestData(for: resource, options: options) { data in
                guard gate.isOpen else { return }
                pieces.append(data)
            } completionHandler: { error in
                if let error, gate.isOpen {
                    pieces.fail((error as NSError).domain == PHPhotosErrorDomain ? ArchiveError.iCloudDownload : error)
                }
                done.signal()
            }
            let limit: TimeInterval = asset.mediaType == .video ? 3600 : 600
            let started = Date()
            while done.wait(timeout: .now() + 2) == .timedOut {
                let quiet = pieces.activity.gotData ? ArchiveActivity.stallLimit : ArchiveActivity.firstTryLimit
                guard pieces.activity.silentFor > quiet || Date().timeIntervalSince(started) > limit else { continue }
                gate.close()
                manager.cancelDataRequest(request)
                if !pieces.activity.gotData, asset.mediaType == .image, ArchiveParts.allowsImageFallback(part: item.part),
                   let data = originalImage(asset, id: id, limit: limit) {
                    pieces.append(data)
                } else {
                    pieces.fail(ArchiveError.iCloudDownload)
                }
                return
            }
        }
    }

    /// Photos' image download of the unedited original, held in memory (photos are a few MB).
    private static func originalImage(_ asset: PHAsset, id: String, limit: TimeInterval) -> Data? {
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
        let done = DispatchSemaphore(value: 0)
        let request = PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
            box.set(data, error: info?[PHImageErrorKey] as? Error)
            done.signal()
        }
        let started = Date()
        while done.wait(timeout: .now() + 2) == .timedOut {
            if activity.silentFor > ArchiveActivity.stallLimit || Date().timeIntervalSince(started) > limit {
                PHImageManager.default().cancelImageRequest(request)
                return nil
            }
        }
        return box.data
    }

    /// A blocking request, so uploads pace the download.
    static func send(_ request: URLRequest, body: Data?) throws -> (status: Int, body: Data) {
        let done = DispatchSemaphore(value: 0)
        let result = ArchiveResultBox()
        let completion: @Sendable (Data?, URLResponse?, Error?) -> Void = { data, response, error in
            result.set(status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data ?? Data(), error: error)
            done.signal()
        }
        let task = body.map { URLSession.shared.uploadTask(with: request, from: $0, completionHandler: completion) }
            ?? URLSession.shared.dataTask(with: request, completionHandler: completion)
        task.resume()
        done.wait()
        return try result.get()
    }

    // MARK: - OneDrive

    static func oneDrive(_ item: ArchiveItem, total: Int64, token: String, folder: OnlineFolder = .root)
        throws -> (stored: Stored, fingerprint: ArchiveFingerprint, local: String) {
        let encoded = OnlineFolders.graphPath(OnlineFolders.joined(folder, item.name))
        var start = URLRequest(url: URL(string: "\(OnlineFolders.oneDriveRoot)/\(encoded):/createUploadSession")!)
        start.httpMethod = "POST"
        start.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Never overwrite: a file with the same name is added beside it under a new name.
        let opened = try send(start, body: try JSONSerialization.data(withJSONObject: ["item": ["@microsoft.graph.conflictBehavior": "rename"]]))
        struct Session: Decodable { let uploadUrl: String }
        guard opened.status == 200, let url = URL(string: try JSONDecoder().decode(Session.self, from: opened.body).uploadUrl) else {
            throw CloudError.server("OneDrive", opened.status)
        }
        let finished = ArchiveStoredBox()
        let pieces = CloudPieces { piece, offset in
            // The size given up front must hold; anything past it would be refused anyway.
            guard offset + Int64(piece.count) <= total else { throw CloudStreamError.sizeChanged }
            try oneDrivePiece(piece, at: offset, total: total, session: url, finished: finished)
        }
        feed(item, into: pieces)
        let result: (fingerprint: ArchiveFingerprint, quickXor: String, dropbox: String)
        do {
            result = try pieces.finish()
        } catch {
            cancel(url)
            throw error
        }
        guard result.fingerprint.bytes == total, let stored = finished.stored else {
            cancel(url)
            throw CloudStreamError.sizeChanged
        }
        return (stored, result.fingerprint, result.quickXor)
    }

    /// Sends one piece to a OneDrive upload session. OneDrive answers with the bytes it still expects,
    /// and whatever it didn't keep is sent again from there. A dropped connection or a busy server is
    /// retried a few times, each time after asking the session where it got to; then the item fails.
    private static func oneDrivePiece(_ piece: Data, at offset: Int64, total: Int64, session url: URL,
                                      finished: ArchiveStoredBox, pause: (Int) -> Void = { UploadRetry.wait($0) }) throws {
        let end = offset + Int64(piece.count)
        var at = offset
        var tries = 0
        while true {
            let rest = Data(piece[(piece.startIndex + Int(at - offset))...])
            var put = URLRequest(url: url)
            put.httpMethod = "PUT"
            put.timeoutInterval = 600
            // The upload address carries its own permission; adding the sign-in can make it fail.
            put.setValue("bytes \(at)-\(end - 1)/\(total)", forHTTPHeaderField: "Content-Range")
            let reply: (status: Int, body: Data)
            do {
                reply = try send(put, body: rest)
                guard [200, 201, 202].contains(reply.status) else { throw CloudError.server("OneDrive", reply.status) }
            } catch {
                guard tries < UploadRetry.attempts, UploadRetry.retryable(error) else { throw error }
                tries += 1
                pause(tries)
                // Where the session got to. If it can't say, the rest of the piece is sent again.
                var ask = URLRequest(url: url)
                ask.httpMethod = "GET"
                if let status = try? send(ask, body: nil), status.status == 200,
                   let next = UploadRetry.oneDriveNext(status.body) {
                    guard next >= offset, next <= end else { throw error }
                    // Every byte of this piece arrived before the connection dropped.
                    if next == end { return }
                    at = next
                }
                continue
            }
            if reply.status != 202 {
                finished.stored = try JSONDecoder().decode(Stored.self, from: reply.body)
                return
            }
            // Accepted; OneDrive says which byte it wants next. Without that, the whole piece counts.
            let next = UploadRetry.oneDriveNext(reply.body) ?? end
            if next >= end { return }
            // It kept only part of the piece: the rest goes again, but only while it keeps moving forward.
            guard next > at, tries < UploadRetry.attempts else { throw CloudError.server("OneDrive", reply.status) }
            tries += 1
            at = next
        }
    }

    /// Drops an unfinished OneDrive upload so no partial file is left.
    private static func cancel(_ session: URL) {
        var request = URLRequest(url: session)
        request.httpMethod = "DELETE"
        _ = try? send(request, body: nil)
    }

    // MARK: - Dropbox

    static func dropbox(_ item: ArchiveItem, token: String, folder: OnlineFolder = .root)
        throws -> (id: String, name: String, size: Int64, hash: String?, fingerprint: ArchiveFingerprint, local: String) {
        func request(_ endpoint: String, arg: [String: Any]) -> URLRequest {
            var request = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/\(endpoint)")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 600
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(DropboxClient.apiArg(arg), forHTTPHeaderField: "Dropbox-API-Arg")
            return request
        }
        struct Started: Decodable { let session_id: String }
        let started = try send(request("upload_session/start", arg: ["close": false]), body: Data())
        guard started.status == 200 else { throw CloudError.server("Dropbox", started.status) }
        let session = try JSONDecoder().decode(Started.self, from: started.body).session_id
        let pieces = CloudPieces { piece, offset in
            let reply = try send(request("upload_session/append_v2", arg: ["cursor": ["session_id": session, "offset": offset], "close": false]),
                                 body: piece)
            guard reply.status == 200 else { throw CloudError.server("Dropbox", reply.status) }
        }
        feed(item, into: pieces)
        let result = try pieces.finish()
        // Never overwrite: a file with the same name is added beside it under a new name.
        let commit: [String: Any] = ["path": "/" + OnlineFolders.joined(folder, item.name), "mode": "add", "autorename": true, "mute": true]
        let done = try send(request("upload_session/finish",
                                    arg: ["cursor": ["session_id": session, "offset": result.fingerprint.bytes], "commit": commit]),
                            body: Data())
        guard done.status == 200 else { throw CloudError.server("Dropbox", done.status) }
        struct Metadata: Decodable { let id: String; let name: String; let size: Int64?; let content_hash: String? }
        let stored = try JSONDecoder().decode(Metadata.self, from: done.body)
        return (stored.id, stored.name, stored.size ?? -1, stored.content_hash, result.fingerprint, result.dropbox)
    }
}

/// When a cloud upload is worth trying again, and how long to wait first. Only a dropped connection
/// or a busy server is retried, a few times; anything else fails the item straight away, as before.
enum UploadRetry {
    static let attempts = 4

    static func retryable(_ error: Error) -> Bool {
        switch error {
        case let GoogleDriveError.server(status): return transient(status)
        case let CloudError.server(_, status): return transient(status)
        default: break
        }
        guard let error = error as? URLError else { return false }
        let dropped: Set<URLError.Code> = [.timedOut, .networkConnectionLost, .notConnectedToInternet,
                                           .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed]
        return dropped.contains(error.code)
    }

    /// Statuses that mean "try again in a moment".
    static func transient(_ status: Int) -> Bool { [408, 429, 500, 502, 503, 504].contains(status) }

    /// 1, 2, 4, then 8 seconds.
    static func delay(_ attempt: Int) -> TimeInterval { min(pow(2, Double(max(attempt, 1) - 1)), 8) }

    static func wait(_ attempt: Int) { Thread.sleep(forTimeInterval: delay(attempt)) }

    /// The first byte a OneDrive upload session still expects, from its `nextExpectedRanges`
    /// ("26214400-" or "26214400-52428799"). Nil when the answer doesn't say.
    static func oneDriveNext(_ body: Data) -> Int64? {
        struct Ranges: Decodable { let nextExpectedRanges: [String]? }
        guard let first = (try? JSONDecoder().decode(Ranges.self, from: body))?.nextExpectedRanges?.first,
              let start = first.split(separator: "-", omittingEmptySubsequences: false).first else { return nil }
        return Int64(start.trimmingCharacters(in: .whitespaces))
    }
}

enum CloudStreamError: Error {
    /// The item turned out a different size than Photos said, so it is sent the other way.
    case sizeChanged
}

final class ArchiveStoredBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: CloudStream.Stored?
    var stored: CloudStream.Stored? {
        get { lock.lock(); defer { lock.unlock() }; return value }
        set { lock.lock(); value = newValue; lock.unlock() }
    }
}

final class ArchiveResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var status = 0
    private var body = Data()
    private var error: Error?
    func set(status: Int, body: Data, error: Error?) { lock.lock(); self.status = status; self.body = body; self.error = error; lock.unlock() }
    func get() throws -> (status: Int, body: Data) {
        lock.lock(); defer { lock.unlock() }
        if let error { throw error }
        return (status, body)
    }
}
