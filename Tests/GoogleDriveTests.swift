import XCTest
@testable import SmartPhotoVault

final class GoogleDriveTests: XCTestCase {
    func testPKCEChallengeIsBase64URLOfSHA256() {
        XCTAssertEqual(PKCE.challenge(for: "tidyaway-test-verifier"), "ljfF7LkOseYwK_oIE7aO5L-PoHqoICf8Ap0dofkLiP4")
        let fresh = PKCE.make()
        XCTAssertGreaterThanOrEqual(fresh.verifier.count, 43, "RFC 7636 needs at least 43 characters.")
        XCTAssertEqual(fresh.challenge, PKCE.challenge(for: fresh.verifier))
        XCTAssertFalse(fresh.verifier.contains("="))
    }

    func testSignInAsksOnlyForTidyAwaysOwnFiles() throws {
        let url = GoogleDriveConfig.authorizeURL(challenge: "abc", state: "xyz")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(value("scope"), "openid email https://www.googleapis.com/auth/drive.file")
        XCTAssertFalse(value("scope")?.contains("auth/drive ") ?? true, "Never the full Drive permission.")
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(value("redirect_uri"), GoogleDriveConfig.redirectScheme + ":/oauth2redirect")
        XCTAssertTrue(GoogleDriveConfig.redirectScheme.hasPrefix("com.googleusercontent.apps."))
        XCTAssertTrue(GoogleDriveConfig.clientID.hasSuffix(".apps.googleusercontent.com"))
    }

    func testEmailIsReadFromTheIDToken() {
        let token = "header.eyJlbWFpbCI6InRlc3RAZXhhbXBsZS5jb20iLCJzdWIiOiIxIn0.signature"
        XCTAssertEqual(GoogleIDToken.email(from: token), "test@example.com")
        XCTAssertNil(GoogleIDToken.email(from: "not-a-token"))
    }

    func testFormBodyEncodesReservedCharacters() {
        let body = String(decoding: GoogleTokenService.formBody(["b": "a b&c", "a": "x/y"]), as: UTF8.self)
        XCTAssertEqual(body, "a=x%2Fy&b=a%20b%26c")
    }

    func testArchiveFolderQueryIsScopedToTheTidyAwayFolder() {
        XCTAssertEqual(GoogleDriveClient.folderQuery(),
                       "name = 'TidyAway Archive' and mimeType = 'application/vnd.google-apps.folder' and trashed = false")
    }

    func testOlderArchivedRecordsStillLoad() throws {
        let old = #"{"id":"1","name":"a.jpg","folderName":"F","bytes":3,"digest":"ab","date":0,"viaHomeServer":false}"#
        let record = try JSONDecoder().decode(ArchivedRecord.self, from: Data(old.utf8))
        XCTAssertNil(record.driveFileID)
    }

    func testFileHashMatchesKnownSHA256() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try GoogleDriveClient.sha256(of: file),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
