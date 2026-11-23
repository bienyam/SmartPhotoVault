import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

/// OneDrive and Dropbox as archive destinations, alongside Google Drive. Each copy counts only when the
/// service's own fingerprint of what it stored matches the original, byte for byte.
enum CloudService: String, Codable, CaseIterable, Sendable {
    case oneDrive = "onedrive"
    case dropbox

    var name: String {
        switch self {
        case .oneDrive: "OneDrive"
        case .dropbox: "Dropbox"
        }
    }

    /// The app's public ID with the service. Empty until the owner registers TidyAway there; until then
    /// the destination isn't offered. Not a secret: mobile apps have none.
    var clientID: String {
        switch self {
        case .oneDrive: CloudKeys.oneDriveClientID
        case .dropbox: CloudKeys.dropboxAppKey
        }
    }

    var available: Bool { !clientID.isEmpty }

    var callbackScheme: String {
        switch self {
        case .oneDrive: "msauth.com.bienyam.SmartPhotoVault"
        case .dropbox: "db-\(clientID)"
        }
    }

    var redirectURI: String {
        switch self {
        case .oneDrive: "\(callbackScheme)://auth"
        case .dropbox: "\(callbackScheme)://2/token"
        }
    }

    /// Where the copies go, as people see it in the service's own app.
    var folderDescription: String {
        switch self {
        case .oneDrive: "Apps › TidyAway in your OneDrive"
        case .dropbox: "Apps › TidyAway in your Dropbox"
        }
    }

    var webLink: URL? {
        switch self {
        case .oneDrive: URL(string: "https://onedrive.live.com/")
        case .dropbox: URL(string: "https://www.dropbox.com/home/Apps")
        }
    }

    func authorizeURL(challenge: String, state: String) -> URL {
        var parts: URLComponents
        var items = [URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "response_type", value: "code"),
                     URLQueryItem(name: "redirect_uri", value: redirectURI), URLQueryItem(name: "state", value: state),
                     URLQueryItem(name: "code_challenge", value: challenge),
                     URLQueryItem(name: "code_challenge_method", value: "S256")]
        switch self {
        case .oneDrive:
            parts = URLComponents(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
            items += [URLQueryItem(name: "scope", value: OneDriveClient.scopes), URLQueryItem(name: "prompt", value: "select_account")]
        case .dropbox:
            parts = URLComponents(string: "https://www.dropbox.com/oauth2/authorize")!
            items += [URLQueryItem(name: "token_access_type", value: "offline")]
        }
        parts.queryItems = items
        return parts.url!
    }

    var tokenURL: URL {
        switch self {
        case .oneDrive: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!
        case .dropbox: URL(string: "https://api.dropboxapi.com/oauth2/token")!
        }
    }
}

/// Filled in once the owner has registered TidyAway with Microsoft and Dropbox.
enum CloudKeys {
    static let oneDriveClientID = "886a3a65-1b14-470d-912f-95093b62372f"
    static let dropboxAppKey = "g6nafhzmh277qey"
}

enum CloudError: LocalizedError, Equatable {
    case cancelled, signInFailed(String), notConnected(String), server(String, Int), verification(String), notConfirmedYet(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: "Sign-in was cancelled."
        case .signInFailed(let name): "\(name) sign-in didn't finish. Try again."
        case .notConnected(let name): "Connect \(name) first."
        case let .server(name, code): "\(name) answered with an error (\(code)). Try again in a moment."
        case .verification(let name): "The copy in \(name) didn't match the original, so it wasn't counted as archived."
        case .notConfirmedYet(let name): "\(name) hasn't confirmed this copy yet, so it wasn't counted as archived. Try again in a moment."
        }
    }
}

struct CloudTokens: Codable, Equatable {
    var accessToken: String
    var expiry: Date
    var refreshToken: String
    var name: String?
}

enum CloudKeychain {
    private static func base(_ service: CloudService) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.bienyam.SmartPhotoVault.\(service.rawValue)",
         kSecAttrAccount as String: "archive"]
    }

    static func load(_ service: CloudService) -> CloudTokens? {
        var query = base(service)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(CloudTokens.self, from: data)
    }

    static func save(_ tokens: CloudTokens, for service: CloudService) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        delete(service)
        var item = base(service)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete(_ service: CloudService) {
        SecItemDelete(base(service) as CFDictionary)
    }
}

/// A signed-in OneDrive or Dropbox account.
@MainActor
final class CloudAccount: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let oneDrive = CloudAccount(.oneDrive)
    static let dropbox = CloudAccount(.dropbox)
    static func shared(_ service: CloudService) -> CloudAccount { service == .oneDrive ? oneDrive : dropbox }

    let service: CloudService
    @Published private(set) var name: String?
    @Published private(set) var busy = false
    @Published var message: String?
    private var tokens: CloudTokens?
    private var session: ASWebAuthenticationSession?

    var connected: Bool { tokens != nil }

    private init(_ service: CloudService) {
        self.service = service
        super.init()
        tokens = CloudKeychain.load(service)
        name = tokens?.name
    }

    func connect() async {
        guard !busy, service.available else { return }
        busy = true
        message = nil
        defer { busy = false }
        let pkce = PKCE.make()
        let state = UUID().uuidString
        do {
            let callback = try await signIn(url: service.authorizeURL(challenge: pkce.challenge, state: state))
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard items.first(where: { $0.name == "state" })?.value == state,
                  let code = items.first(where: { $0.name == "code" })?.value else { throw CloudError.signInFailed(service.name) }
            var fresh = try await CloudTokenService.exchange(service, code: code, verifier: pkce.verifier)
            if service == .dropbox { fresh.name = await DropboxClient.accountEmail(token: fresh.accessToken) }
            tokens = fresh
            name = fresh.name ?? service.name
            CloudKeychain.save(fresh, for: service)
            try? InventoryStore.openDefault().log("Connected \(service.name) for archiving (TidyAway's own folder only).")
        } catch CloudError.cancelled {
            message = nil
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "\(service.name) sign-in didn't finish. Try again."
        }
    }

    /// Forgets the account on this iPhone. Archived files stay in the service.
    func disconnect() async {
        if service == .dropbox, let token = tokens?.accessToken { await DropboxClient.revoke(token: token) }
        CloudKeychain.delete(service)
        tokens = nil
        name = nil
        try? InventoryStore.openDefault().log("Disconnected \(service.name). Archived copies stay there.")
    }

    func accessToken() async throws -> String {
        guard var current = tokens else { throw CloudError.notConnected(service.name) }
        if current.expiry.timeIntervalSinceNow > 120 { return current.accessToken }
        let refreshed = try await CloudTokenService.refresh(service, current.refreshToken)
        current.accessToken = refreshed.accessToken
        current.expiry = refreshed.expiry
        if let token = refreshed.refreshToken { current.refreshToken = token }
        tokens = current
        CloudKeychain.save(current, for: service)
        return current.accessToken
    }

    private func signIn(url: URL) async throws -> URL {
        let name = service.name
        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: service.callbackScheme) { callback, error in
                if let callback { continuation.resume(returning: callback) }
                else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: CloudError.cancelled)
                } else { continuation.resume(throwing: CloudError.signInFailed(name)) }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() { continuation.resume(throwing: CloudError.signInFailed(name)) }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}

enum CloudTokenService {
    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Double
        let refresh_token: String?
        let id_token: String?
    }

    static func exchange(_ service: CloudService, code: String, verifier: String) async throws -> CloudTokens {
        var fields = ["code": code, "client_id": service.clientID, "redirect_uri": service.redirectURI,
                      "grant_type": "authorization_code", "code_verifier": verifier]
        if service == .oneDrive { fields["scope"] = OneDriveClient.scopes }
        let response = try await post(service, fields)
        guard let refresh = response.refresh_token else { throw CloudError.signInFailed(service.name) }
        return CloudTokens(accessToken: response.access_token, expiry: Date().addingTimeInterval(response.expires_in),
                           refreshToken: refresh, name: response.id_token.flatMap(Self.username(from:)))
    }

    static func refresh(_ service: CloudService, _ refreshToken: String) async throws -> (accessToken: String, expiry: Date, refreshToken: String?) {
        var fields = ["refresh_token": refreshToken, "client_id": service.clientID, "grant_type": "refresh_token"]
        if service == .oneDrive { fields["scope"] = OneDriveClient.scopes }
        let response = try await post(service, fields)
        return (response.access_token, Date().addingTimeInterval(response.expires_in), response.refresh_token)
    }

    /// The sign-in name inside Microsoft's ID token, shown as "Connected as …". Display only.
    static func username(from idToken: String) -> String? {
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2, let payload = Data(base64URL: String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        return (json["email"] as? String) ?? (json["preferred_username"] as? String)
    }

    private static func post(_ service: CloudService, _ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: service.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GoogleTokenService.formBody(fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw CloudError.signInFailed(service.name) }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }
}

// MARK: - Fingerprints the services use

/// Microsoft's QuickXorHash, the one fingerprint OneDrive gives for every account. Ported from
/// Microsoft's published C# and checked against known results in the tests.
struct QuickXorHash {
    private static let widthInBits = 160
    private static let shift = 11
    private static let bitsInLastCell = 32

    private var data = [UInt64](repeating: 0, count: 3)
    private var lengthSoFar: Int64 = 0
    private var shiftSoFar = 0

    mutating func update(_ bytes: Data) {
        bytes.withUnsafeBytes { raw in
            let array = raw.bindMemory(to: UInt8.self)
            let size = array.count
            guard size > 0 else { return }
            var vectorArrayIndex = shiftSoFar / 64
            var vectorOffset = shiftSoFar % 64
            let iterations = min(size, Self.widthInBits)
            for i in 0..<iterations {
                let isLastCell = vectorArrayIndex == data.count - 1
                let bitsInVectorCell = isLastCell ? Self.bitsInLastCell : 64
                if vectorOffset <= bitsInVectorCell - 8 {
                    var j = i
                    while j < size {
                        data[vectorArrayIndex] ^= UInt64(array[j]) << UInt64(vectorOffset)
                        j += Self.widthInBits
                    }
                } else {
                    let index1 = vectorArrayIndex
                    let index2 = isLastCell ? 0 : vectorArrayIndex + 1
                    let low = bitsInVectorCell - vectorOffset
                    var xored: UInt8 = 0
                    var j = i
                    while j < size {
                        xored ^= array[j]
                        j += Self.widthInBits
                    }
                    data[index1] ^= UInt64(xored) << UInt64(vectorOffset)
                    data[index2] ^= UInt64(xored) >> UInt64(low)
                }
                vectorOffset += Self.shift
                while vectorOffset >= bitsInVectorCell {
                    vectorArrayIndex = isLastCell ? 0 : vectorArrayIndex + 1
                    vectorOffset -= bitsInVectorCell
                }
            }
            shiftSoFar = (shiftSoFar + Self.shift * (size % Self.widthInBits)) % Self.widthInBits
        }
        lengthSoFar += Int64(bytes.count)
    }

    /// Base64, as OneDrive reports it.
    func finalize() -> String {
        var result = [UInt8](repeating: 0, count: 20)
        for cell in 0..<data.count {
            let little = withUnsafeBytes(of: data[cell].littleEndian) { Array($0) }
            let start = cell * 8
            for k in 0..<min(8, 20 - start) { result[start + k] = little[k] }
        }
        let length = withUnsafeBytes(of: lengthSoFar.littleEndian) { Array($0) }
        for k in 0..<8 { result[12 + k] ^= length[k] }
        return Data(result).base64EncodedString()
    }
}

/// Dropbox's content hash: SHA-256 of each 4 MB block, then SHA-256 of those, in hex.
struct DropboxContentHash {
    static let blockSize = 4 * 1024 * 1024
    private var overall = SHA256()
    private var block = SHA256()
    private var inBlock = 0

    mutating func update(_ bytes: Data) {
        var rest = bytes[...]
        while !rest.isEmpty {
            let take = min(Self.blockSize - inBlock, rest.count)
            block.update(data: rest.prefix(take))
            inBlock += take
            rest = rest.dropFirst(take)
            if inBlock == Self.blockSize { closeBlock() }
        }
    }

    private mutating func closeBlock() {
        overall.update(data: Data(block.finalize()))
        block = SHA256()
        inBlock = 0
    }

    mutating func finalize() -> String {
        if inBlock > 0 { closeBlock() }
        return overall.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Uploading

/// One archived item in a cloud service.
struct CloudUpload: Sendable {
    let fileID: String
    let name: String
    let fingerprint: ArchiveFingerprint
    /// The service's own fingerprint of the stored copy, matched before this upload counted.
    let serviceHash: String
}

/// What the service says about a stored copy now.
struct CloudStoredFile: Equatable, Sendable {
    let bytes: Int64
    let hash: String?
}

enum CloudArchive {
    /// Pieces sent at a time: 10 MiB suits both (OneDrive needs multiples of 320 KiB, Dropbox of 4 MiB is ideal).
    static let pieceSize = 32 * 327_680

    /// Streams the item straight to the service in pieces as Photos hands them over, so no copy needs
    /// room on the iPhone, then matches the service's fingerprint of what it stored. OneDrive needs the
    /// size up front; when it isn't known, or the item turns out a different size, it goes the older way.
    static func upload(_ item: ArchiveItem, to service: CloudService, token: String) async throws -> CloudUpload {
        do {
            return try await streamed(item, to: service, token: token)
        } catch CloudStreamError.sizeChanged {
            return try await throughFile(item, to: service, token: token)
        }
    }

    private static func streamed(_ item: ArchiveItem, to service: CloudService, token: String) async throws -> CloudUpload {
        switch service {
        case .oneDrive:
            guard let total = CloudStream.knownSize(of: item), total > 0 else { throw CloudStreamError.sizeChanged }
            let sent = try await Task.detached(priority: .userInitiated) { try CloudStream.oneDrive(item, total: total, token: token) }.value
            try check(item, sent.fingerprint)
            // OneDrive may need a moment to fingerprint a new file.
            var stored = try await OneDriveClient.stored(sent.stored.id, token: token)
            for wait in [1, 2, 4] where stored.hash == nil {
                try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
                stored = try await OneDriveClient.stored(sent.stored.id, token: token)
            }
            guard stored.bytes == sent.fingerprint.bytes else { throw CloudError.verification(service.name) }
            guard let hash = stored.hash else { throw CloudError.notConfirmedYet(service.name) }
            guard sameHash(hash, sent.local, service: service) else { throw CloudError.verification(service.name) }
            return CloudUpload(fileID: sent.stored.id, name: sent.stored.name ?? item.name, fingerprint: sent.fingerprint, serviceHash: sent.local)
        case .dropbox:
            let sent = try await Task.detached(priority: .userInitiated) { try CloudStream.dropbox(item, token: token) }.value
            try check(item, sent.fingerprint)
            guard sent.size == sent.fingerprint.bytes else { throw CloudError.verification(service.name) }
            guard let hash = sent.hash else { throw CloudError.notConfirmedYet(service.name) }
            guard sameHash(hash, sent.local, service: service) else { throw CloudError.verification(service.name) }
            return CloudUpload(fileID: sent.id, name: sent.name, fingerprint: sent.fingerprint, serviceHash: sent.local)
        }
    }

    /// A photo the scan read in full must arrive exactly as it was read.
    private static func check(_ item: ArchiveItem, _ fingerprint: ArchiveFingerprint) throws {
        if case let .photo(_, expected) = item.source, let expected,
           fingerprint != ArchiveFingerprint(bytes: expected.bytes, digest: expected.digest) {
            throw ArchiveError.verification
        }
    }

    /// The older way: a temporary copy on the iPhone, then the upload. Needs room for the item.
    private static func throughFile(_ item: ArchiveItem, to service: CloudService, token: String) async throws -> CloudUpload {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("TidyAwayUpload-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let local = try await Task.detached(priority: .userInitiated) {
            try VerifiedArchive.copy(item, to: folder, flush: false)
        }.value
        let result: (id: String, name: String, hash: String?, size: Int64, local: String)
        switch service {
        case .oneDrive: result = try await OneDriveClient.upload(local.url, name: item.name, token: token)
        case .dropbox: result = try await DropboxClient.upload(local.url, name: item.name, token: token)
        }
        guard result.size == local.fingerprint.bytes else { throw CloudError.verification(service.name) }
        guard let hash = result.hash else { throw CloudError.notConfirmedYet(service.name) }
        guard sameHash(hash, result.local, service: service) else { throw CloudError.verification(service.name) }
        return CloudUpload(fileID: result.id, name: result.name, fingerprint: local.fingerprint, serviceHash: result.local)
    }

    static func sameHash(_ reported: String, _ expected: String, service: CloudService) -> Bool {
        switch service {
        case .oneDrive: reported == expected
        case .dropbox: reported.lowercased() == expected.lowercased()
        }
    }

    static func stored(_ fileID: String, in service: CloudService, token: String) async throws -> CloudStoredFile {
        switch service {
        case .oneDrive: try await OneDriveClient.stored(fileID, token: token)
        case .dropbox: try await DropboxClient.stored(fileID, token: token)
        }
    }

    /// Downloads an archived copy to a temporary file and returns it with its SHA-256.
    static func download(_ fileID: String, from service: CloudService, token: String) async throws -> (url: URL, digest: String) {
        var request: URLRequest
        switch service {
        case .oneDrive:
            request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/\(fileID)/content")!)
        case .dropbox:
            request = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/download")!)
            request.httpMethod = "POST"
            request.setValue(DropboxClient.apiArg(["path": fileID]), forHTTPHeaderField: "Dropbox-API-Arg")
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 3600
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CloudError.server(service.name, (response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return (temporary, try GoogleDriveClient.sha256(of: temporary))
    }

    static func send(_ request: URLRequest, body: Data? = nil, service: CloudService) async throws -> (Int, Data) {
        let data: Data, response: URLResponse
        if let body { (data, response) = try await URLSession.shared.upload(for: request, from: body) }
        else { (data, response) = try await URLSession.shared.data(for: request) }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// Reads a file in pieces, feeding each to `hash` and `send`.
    static func pieces(of file: URL, _ each: (Data, Int64) async throws -> Void) async throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var offset: Int64 = 0
        while let piece = try handle.read(upToCount: pieceSize), !piece.isEmpty {
            try await each(piece, offset)
            offset += Int64(piece.count)
            ArchiveLive.shared.uploaded(piece.count)
        }
    }
}

enum OneDriveClient {
    /// Only TidyAway's own app folder (Apps › TidyAway), never the rest of someone's OneDrive.
    static let scopes = "openid profile offline_access Files.ReadWrite.AppFolder"

    private struct Item: Decodable {
        struct File: Decodable {
            struct Hashes: Decodable { let quickXorHash: String? }
            let hashes: Hashes?
        }
        let id: String
        let name: String?
        let size: Int64?
        let file: File?
    }

    static func upload(_ file: URL, name: String, token: String) async throws -> (id: String, name: String, hash: String?, size: Int64, local: String) {
        let total = try VerifiedArchive.storedSize(of: file)
        let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/:"))) ?? name
        var start = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/drive/special/approot:/\(encoded):/createUploadSession")!)
        start.httpMethod = "POST"
        start.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Never overwrite: a file with the same name is added beside it under a new name.
        let body = try JSONSerialization.data(withJSONObject: ["item": ["@microsoft.graph.conflictBehavior": "rename"]])
        let (status, data) = try await CloudArchive.send(start, body: body, service: .oneDrive)
        struct Session: Decodable { let uploadUrl: String }
        guard status == 200, let url = URL(string: try JSONDecoder().decode(Session.self, from: data).uploadUrl) else {
            throw CloudError.server("OneDrive", status)
        }
        var quick = QuickXorHash()
        var finished: Item?
        try await CloudArchive.pieces(of: file) { piece, offset in
            quick.update(piece)
            var put = URLRequest(url: url)
            put.httpMethod = "PUT"
            put.timeoutInterval = 600
            // The upload address carries its own permission; adding the sign-in can make it fail.
            put.setValue("bytes \(offset)-\(offset + Int64(piece.count) - 1)/\(total)", forHTTPHeaderField: "Content-Range")
            let (code, reply) = try await CloudArchive.send(put, body: piece, service: .oneDrive)
            switch code {
            case 202: break
            case 200, 201: finished = try JSONDecoder().decode(Item.self, from: reply)
            default: throw CloudError.server("OneDrive", code)
            }
        }
        guard let item = finished else { throw CloudError.server("OneDrive", 0) }
        let local = quick.finalize()
        // OneDrive may need a moment to fingerprint a new file.
        var stored = try await Self.stored(item.id, token: token)
        for wait in [1, 2, 4] where stored.hash == nil {
            try await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
            stored = try await Self.stored(item.id, token: token)
        }
        return (item.id, item.name ?? name, stored.hash, stored.bytes, local)
    }

    static func stored(_ fileID: String, token: String) async throws -> CloudStoredFile {
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me/drive/items/\(fileID)?$select=id,size,file")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let (status, data) = try await CloudArchive.send(request, service: .oneDrive)
        if status == 404 { throw ArchiveProofError.copyMissing }
        guard status == 200 else { throw CloudError.server("OneDrive", status) }
        let item = try JSONDecoder().decode(Item.self, from: data)
        guard let size = item.size, item.file != nil else { throw ArchiveProofError.copyMissing }
        return CloudStoredFile(bytes: size, hash: item.file?.hashes?.quickXorHash)
    }
}

enum DropboxClient {
    private struct Metadata: Decodable {
        let tag: String?
        let id: String
        let name: String
        let size: Int64?
        let content_hash: String?
        enum CodingKeys: String, CodingKey { case tag = ".tag", id, name, size, content_hash }
    }

    /// The Dropbox-API-Arg header: JSON with every non-ASCII character written as \uXXXX, as Dropbox requires.
    static func apiArg(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        let text = String(decoding: data, as: UTF8.self)
        var out = ""
        for unit in text.utf16 {
            if unit < 0x80 { out.unicodeScalars.append(Unicode.Scalar(unit)!) }
            else { out += String(format: "\\u%04x", unit) }
        }
        return out
    }

    static func upload(_ file: URL, name: String, token: String) async throws -> (id: String, name: String, hash: String?, size: Int64, local: String) {
        let total = try VerifiedArchive.storedSize(of: file)
        var content = DropboxContentHash()
        var sessionID: String?
        func request(_ endpoint: String, arg: [String: Any]) -> URLRequest {
            var request = URLRequest(url: URL(string: "https://content.dropboxapi.com/2/files/\(endpoint)")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 600
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue(apiArg(arg), forHTTPHeaderField: "Dropbox-API-Arg")
            return request
        }
        try await CloudArchive.pieces(of: file) { piece, offset in
            content.update(piece)
            if let id = sessionID {
                let (code, _) = try await CloudArchive.send(request("upload_session/append_v2",
                                                                    arg: ["cursor": ["session_id": id, "offset": offset], "close": false]),
                                                            body: piece, service: .dropbox)
                guard code == 200 else { throw CloudError.server("Dropbox", code) }
            } else {
                let (code, reply) = try await CloudArchive.send(request("upload_session/start", arg: ["close": false]),
                                                                body: piece, service: .dropbox)
                struct Started: Decodable { let session_id: String }
                guard code == 200 else { throw CloudError.server("Dropbox", code) }
                sessionID = try JSONDecoder().decode(Started.self, from: reply).session_id
            }
        }
        if sessionID == nil {
            let (code, reply) = try await CloudArchive.send(request("upload_session/start", arg: ["close": false]), body: Data(), service: .dropbox)
            struct Started: Decodable { let session_id: String }
            guard code == 200 else { throw CloudError.server("Dropbox", code) }
            sessionID = try JSONDecoder().decode(Started.self, from: reply).session_id
        }
        // Never overwrite: a file with the same name is added beside it under a new name.
        let commit: [String: Any] = ["path": "/\(name)", "mode": "add", "autorename": true, "mute": true]
        let (code, reply) = try await CloudArchive.send(request("upload_session/finish",
                                                                arg: ["cursor": ["session_id": sessionID!, "offset": total], "commit": commit]),
                                                        body: Data(), service: .dropbox)
        guard code == 200 else { throw CloudError.server("Dropbox", code) }
        let stored = try JSONDecoder().decode(Metadata.self, from: reply)
        return (stored.id, stored.name, stored.content_hash, stored.size ?? -1, content.finalize())
    }

    static func stored(_ fileID: String, token: String) async throws -> CloudStoredFile {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/files/get_metadata")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (status, data) = try await CloudArchive.send(request, body: try JSONSerialization.data(withJSONObject: ["path": fileID]), service: .dropbox)
        // Dropbox answers 409 when the file is gone.
        if status == 409 { throw ArchiveProofError.copyMissing }
        guard status == 200 else { throw CloudError.server("Dropbox", status) }
        let item = try JSONDecoder().decode(Metadata.self, from: data)
        guard item.tag == "file", let size = item.size else { throw ArchiveProofError.copyMissing }
        return CloudStoredFile(bytes: size, hash: item.content_hash)
    }

    static func accountEmail(token: String) async -> String? {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/users/get_current_account")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        struct Account: Decodable { let email: String? }
        guard let (status, data) = try? await CloudArchive.send(request, service: .dropbox), status == 200 else { return nil }
        return (try? JSONDecoder().decode(Account.self, from: data))?.email
    }

    static func revoke(token: String) async {
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/2/auth/token/revoke")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        _ = try? await CloudArchive.send(request, service: .dropbox)
    }
}
