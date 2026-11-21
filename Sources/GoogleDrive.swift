import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

/// Google sign-in for TidyAway. Uses Google's own sign-in page in Apple's secure browser sheet,
/// with PKCE and the narrow `drive.file` permission: TidyAway can only see and add files it created,
/// so it can never read, change or delete anything else in someone's Drive.
enum GoogleDriveConfig {
    /// iOS OAuth client in the "tidyaway" Google Cloud project. Not a secret: iOS clients have none.
    static let clientID = "168234077611-89hkbg3u2gm6eith2ti47d4mcht334mc.apps.googleusercontent.com"
    static let redirectScheme = "com.googleusercontent.apps.168234077611-89hkbg3u2gm6eith2ti47d4mcht334mc"
    static var redirectURI: String { redirectScheme + ":/oauth2redirect" }
    static let scopes = "openid email https://www.googleapis.com/auth/drive.file"
    static let folderName = "TidyAway Archive"

    static func authorizeURL(challenge: String, state: String) -> URL {
        var parts = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        parts.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "consent")
        ]
        return parts.url!
    }
}

/// Proof Key for Code Exchange: the sign-in code is useless without the verifier kept on this iPhone.
struct PKCE {
    let verifier: String
    let challenge: String

    static func make() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let verifier = Data(bytes).base64URL
        return PKCE(verifier: verifier, challenge: challenge(for: verifier))
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var text = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        self.init(base64Encoded: text)
    }
}

enum GoogleIDToken {
    /// The email inside Google's ID token, shown as "Connected as …". Display only, never trusted for access.
    static func email(from idToken: String) -> String? {
        let parts = idToken.split(separator: ".")
        guard parts.count >= 2, let payload = Data(base64URL: String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { return nil }
        return json["email"] as? String
    }
}

struct GoogleTokens: Codable, Equatable {
    var accessToken: String
    var expiry: Date
    var refreshToken: String
    var email: String?
}

/// Sign-in tokens live in the iPhone Keychain, readable only by TidyAway on this device.
enum GoogleKeychain {
    private static let service = "com.bienyam.SmartPhotoVault.google"
    private static let account = "drive"

    static func load() -> GoogleTokens? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(GoogleTokens.self, from: data)
    }

    static func save(_ tokens: GoogleTokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        delete()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecValueData as String: data,
                                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

enum GoogleDriveError: LocalizedError, Equatable {
    case cancelled, signInFailed, notConnected, server(Int), verification, noSpace

    var errorDescription: String? {
        switch self {
        case .cancelled: "Sign-in was cancelled."
        case .signInFailed: "Google sign-in didn't finish. Try again."
        case .notConnected: "Connect Google Drive first."
        case .server(let code): "Google Drive answered with an error (\(code)). Try again in a moment."
        case .verification: "The copy in Google Drive didn't match the original, so it wasn't counted as archived."
        case .noSpace: "This iPhone doesn't have enough free space to prepare this item for upload."
        }
    }
}

/// The signed-in Google account, shared by the Archive and Get back screens.
@MainActor
final class GoogleDriveAccount: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    static let shared = GoogleDriveAccount()

    @Published private(set) var email: String?
    @Published private(set) var busy = false
    @Published var message: String?
    private var tokens: GoogleTokens?
    private var session: ASWebAuthenticationSession?

    var connected: Bool { tokens != nil }

    override init() {
        super.init()
        tokens = GoogleKeychain.load()
        email = tokens?.email
    }

    /// Opens Google's sign-in page. Google asks the person to allow TidyAway to see and add only
    /// the files it creates.
    func connect() async {
        guard !busy else { return }
        busy = true
        message = nil
        defer { busy = false }
        let pkce = PKCE.make()
        let state = UUID().uuidString
        do {
            let callback = try await signIn(url: GoogleDriveConfig.authorizeURL(challenge: pkce.challenge, state: state))
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard items.first(where: { $0.name == "state" })?.value == state,
                  let code = items.first(where: { $0.name == "code" })?.value else { throw GoogleDriveError.signInFailed }
            let fresh = try await GoogleTokenService.exchange(code: code, verifier: pkce.verifier)
            tokens = fresh
            email = fresh.email
            GoogleKeychain.save(fresh)
            try? InventoryStore.openDefault().log("Connected Google Drive for archiving (TidyAway's own files only).")
        } catch GoogleDriveError.cancelled {
            message = nil
        } catch {
            message = (error as? LocalizedError)?.errorDescription ?? "Google sign-in didn't finish. Try again."
        }
    }

    /// Forgets the account on this iPhone and asks Google to revoke TidyAway's access.
    /// Archived files stay in Google Drive.
    func disconnect() async {
        if let token = tokens?.refreshToken { await GoogleTokenService.revoke(token) }
        GoogleKeychain.delete()
        tokens = nil
        email = nil
        try? InventoryStore.openDefault().log("Disconnected Google Drive. Archived copies stay in Drive.")
    }

    /// A current access token, refreshed when it's about to expire.
    func accessToken() async throws -> String {
        guard var current = tokens else { throw GoogleDriveError.notConnected }
        if current.expiry.timeIntervalSinceNow > 120 { return current.accessToken }
        let refreshed = try await GoogleTokenService.refresh(current.refreshToken)
        current.accessToken = refreshed.accessToken
        current.expiry = refreshed.expiry
        tokens = current
        GoogleKeychain.save(current)
        return current.accessToken
    }

    private func signIn(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: GoogleDriveConfig.redirectScheme) { callback, error in
                if let callback { continuation.resume(returning: callback) }
                else if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: GoogleDriveError.cancelled)
                } else { continuation.resume(throwing: GoogleDriveError.signInFailed) }
            }
            session.presentationContextProvider = self
            self.session = session
            if !session.start() { continuation.resume(throwing: GoogleDriveError.signInFailed) }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows).first { $0.isKeyWindow } ?? ASPresentationAnchor()
        }
    }
}

enum GoogleTokenService {
    private struct TokenResponse: Decodable {
        let access_token: String
        let expires_in: Double
        let refresh_token: String?
        let id_token: String?
    }

    static func exchange(code: String, verifier: String) async throws -> GoogleTokens {
        let response = try await post(["code": code, "client_id": GoogleDriveConfig.clientID,
                                       "redirect_uri": GoogleDriveConfig.redirectURI,
                                       "grant_type": "authorization_code", "code_verifier": verifier])
        guard let refresh = response.refresh_token else { throw GoogleDriveError.signInFailed }
        return GoogleTokens(accessToken: response.access_token, expiry: Date().addingTimeInterval(response.expires_in),
                            refreshToken: refresh, email: response.id_token.flatMap(GoogleIDToken.email(from:)))
    }

    static func refresh(_ refreshToken: String) async throws -> (accessToken: String, expiry: Date) {
        let response = try await post(["refresh_token": refreshToken, "client_id": GoogleDriveConfig.clientID,
                                       "grant_type": "refresh_token"])
        return (response.access_token, Date().addingTimeInterval(response.expires_in))
    }

    static func revoke(_ token: String) async {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(["token": token])
        _ = try? await URLSession.shared.data(for: request)
    }

    static func formBody(_ fields: [String: String]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return Data(fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&").utf8)
    }

    private static func post(_ fields: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody(fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw GoogleDriveError.signInFailed }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }
}

/// Write-only archive in Google Drive: creates a "TidyAway Archive" folder and adds new files to it.
/// It never updates or deletes a file there.
enum GoogleDriveClient {
    struct UploadedFile: Decodable {
        let id: String
        let sha256Checksum: String?
        let size: String?
    }

    static func folderQuery() -> String {
        "name = '\(GoogleDriveConfig.folderName)' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"
    }

    /// The archive folder's ID, creating it the first time. With `drive.file`, TidyAway only sees folders it made.
    static func archiveFolder(token: String) async throws -> String {
        var search = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        search.queryItems = [URLQueryItem(name: "q", value: folderQuery()), URLQueryItem(name: "fields", value: "files(id)"),
                             URLQueryItem(name: "spaces", value: "drive")]
        struct List: Decodable { struct File: Decodable { let id: String }; let files: [File] }
        let found: List = try await send(URLRequest(url: search.url!), token: token)
        if let existing = found.files.first { return existing.id }
        var create = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files?fields=id")!)
        create.httpMethod = "POST"
        create.setValue("application/json", forHTTPHeaderField: "Content-Type")
        create.httpBody = try JSONSerialization.data(withJSONObject: ["name": GoogleDriveConfig.folderName,
                                                                      "mimeType": "application/vnd.google-apps.folder"])
        let folder: UploadedFile = try await send(create, token: token)
        return folder.id
    }

    /// Downloads an archived file to a temporary location and hashes it.
    static func download(_ fileID: String, token: String) async throws -> (url: URL, digest: String) {
        var request = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(fileID)?alt=media")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 3600
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw GoogleDriveError.server((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return (temporary, try sha256(of: temporary))
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func send<T: Decodable>(_ request: URLRequest, token: String) async throws -> T {
        var request = request
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let code = (response as? HTTPURLResponse)?.statusCode, (200...299).contains(code) else {
            throw GoogleDriveError.server((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
