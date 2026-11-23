import CryptoKit
import XCTest
@testable import SmartPhotoVault

final class CloudArchiveTests: XCTestCase {
    /// Known results (from rclone's tests of the same algorithm). The input and output are base64.
    func testQuickXorHashMatchesKnownResults() throws {
        let vectors = [("", "AAAAAAAAAAAAAAAAAAAAAAAAAAA="),
                       ("Sg==", "SgAAAAAAAAAAAAAAAQAAAAAAAAA="),
                       ("0pZP", "0rDEEwAAAAAAAAAAAwAAAAAAAAA="),
                       ("jRRDVA==", "jaDAEKgAAAAAAAAABAAAAAAAAAA="),
                       ("/aNzzCFPS/A=", "/RjFHJgRgicsAR4ACAAAAAAAAAA=")]
        for (input, expected) in vectors {
            var hash = QuickXorHash()
            hash.update(try XCTUnwrap(Data(base64Encoded: input)))
            XCTAssertEqual(hash.finalize(), expected, input)
        }
    }

    func testQuickXorHashIsTheSameHoweverTheBytesArrive() {
        let bytes = Data((0..<5_000).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ $0 / 7) })
        var whole = QuickXorHash()
        whole.update(bytes)
        for size in [1, 3, 19, 20, 21, 159, 160, 161, 1_000] {
            var pieces = QuickXorHash()
            var start = 0
            while start < bytes.count {
                pieces.update(bytes.subdata(in: start..<min(start + size, bytes.count)))
                start += size
            }
            XCTAssertEqual(pieces.finalize(), whole.finalize(), "pieces of \(size)")
        }
    }

    func testDropboxContentHashUsesFourMegabyteBlocks() {
        var empty = DropboxContentHash()
        XCTAssertEqual(empty.finalize(), SHA256.hash(data: Data()).map { String(format: "%02x", $0) }.joined())

        let block = DropboxContentHash.blockSize
        let bytes = Data((0..<(block * 2 + 12_345)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let blocks = [bytes.prefix(block), bytes.dropFirst(block).prefix(block), bytes.dropFirst(block * 2)]
        let joined = blocks.reduce(Data()) { $0 + Data(SHA256.hash(data: $1)) }
        let expected = SHA256.hash(data: joined).map { String(format: "%02x", $0) }.joined()
        for size in [1_000_003, block, 10 * 327_680] {
            var hash = DropboxContentHash()
            var start = 0
            while start < bytes.count {
                hash.update(bytes.subdata(in: start..<min(start + size, bytes.count)))
                start += size
            }
            XCTAssertEqual(hash.finalize(), expected, "pieces of \(size)")
        }
    }

    func testDropboxHeaderEscapesEverythingOutsideASCII() {
        let arg = DropboxClient.apiArg(["path": "/Café 🌅.HEIC"])
        XCTAssertTrue(arg.allSatisfy(\.isASCII), arg)
        XCTAssertTrue(arg.contains("\\u00e9"), arg)
        XCTAssertTrue(arg.contains("\\ud83c\\udf05"), arg)
        let decoded = try? JSONSerialization.jsonObject(with: Data(arg.utf8)) as? [String: String]
        XCTAssertEqual(decoded?["path"], "/Café 🌅.HEIC")
    }

    func testACloudCopyMustMatchItsSizeAndTheServicesFingerprint() {
        let record = ArchivedRecord(id: "r", name: "a.heic", folderName: "OneDrive", bytes: 10, digest: "ab", date: Date(),
                                    viaHomeServer: false, folderBookmark: nil, driveFileID: "f", cloud: .oneDrive, cloudHash: "Qx==")
        XCTAssertNoThrow(try ArchiveProver.stamp(of: CloudStoredFile(bytes: 10, hash: "Qx=="), for: record, in: .oneDrive))
        XCTAssertThrowsError(try ArchiveProver.stamp(of: CloudStoredFile(bytes: 9, hash: "Qx=="), for: record, in: .oneDrive))
        XCTAssertThrowsError(try ArchiveProver.stamp(of: CloudStoredFile(bytes: 10, hash: "Qy=="), for: record, in: .oneDrive))
        XCTAssertThrowsError(try ArchiveProver.stamp(of: CloudStoredFile(bytes: 10, hash: nil), for: record, in: .oneDrive),
                             "No fingerprint from the service: not safe to delete.")
    }

    func testRecordsSavedBeforeCloudsStillLoad() throws {
        let old = #"{"id":"r","name":"a.heic","folderName":"Google Drive","bytes":10,"digest":"ab","date":0,"viaHomeServer":false,"driveFileID":"g"}"#
        let record = try JSONDecoder().decode(ArchivedRecord.self, from: Data(old.utf8))
        XCTAssertNil(record.cloud)
        XCTAssertEqual(record.driveFileID, "g")
        let saved = ArchivedRecord(id: "r", name: "a", folderName: "Dropbox", bytes: 1, digest: "d", date: Date(), viaHomeServer: false,
                                   folderBookmark: nil, driveFileID: "id:x", cloud: .dropbox, cloudHash: "h")
        XCTAssertEqual(try JSONDecoder().decode(ArchivedRecord.self, from: JSONEncoder().encode(saved)), saved)
    }

    func testCloudsStayHiddenUntilTidyAwayIsRegistered() {
        for service in CloudService.allCases {
            XCTAssertEqual(service.available, !service.clientID.isEmpty)
        }
    }
}
