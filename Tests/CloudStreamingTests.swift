import CryptoKit
import XCTest
@testable import SmartPhotoVault

final class CloudStreamingTests: XCTestCase {
    private final class Recorder: @unchecked Sendable {
        var pieces: [(offset: Int64, count: Int)] = []
        var bytes = Data()
    }

    func testPiecesGoOutInOrderWithoutAFullCopyAndFingerprintsMatch() throws {
        let recorder = Recorder()
        let pieces = CloudPieces { piece, offset in
            recorder.pieces.append((offset, piece.count))
            recorder.bytes.append(piece)
        }
        var source = Data()
        for i in 0..<(25 * 1024) { source.append(Data(repeating: UInt8(i % 251), count: 1024)) }
        // Photos hands data over in uneven chunks.
        var at = 0
        while at < source.count {
            let next = min(source.count, at + 700_001)
            pieces.append(source.subdata(in: at..<next))
            at = next
        }
        let result = try pieces.finish()

        let size = CloudPieces.pieceSize
        XCTAssertEqual(recorder.pieces.map(\.offset), [0, Int64(size), Int64(2 * size)])
        XCTAssertEqual(recorder.pieces.dropLast().map(\.count), [size, size], "Every piece but the last is a full piece.")
        XCTAssertEqual(size % 327_680, 0, "OneDrive needs multiples of 320 KiB.")
        XCTAssertEqual(recorder.bytes, source)
        XCTAssertEqual(result.fingerprint.bytes, Int64(source.count))
        XCTAssertEqual(result.fingerprint.digest, SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined())
        var quick = QuickXorHash()
        quick.update(source)
        XCTAssertEqual(result.quickXor, quick.finalize())
        var box = DropboxContentHash()
        box.update(source)
        XCTAssertEqual(result.dropbox, box.finalize())
    }

    func testAFailedPieceStopsTheUpload() {
        struct Refused: Error {}
        let recorder = Recorder()
        let pieces = CloudPieces { piece, offset in
            recorder.pieces.append((offset, piece.count))
            throw Refused()
        }
        pieces.append(Data(count: CloudPieces.pieceSize * 2))
        XCTAssertEqual(recorder.pieces.count, 1, "Nothing more is sent after a refusal.")
        XCTAssertThrowsError(try pieces.finish())
    }

    func testOneDriveNeedsAKnownSize() {
        let unknown = ArchiveItem(id: "1", name: "a.heic", source: .photo("p", expected: nil))
        XCTAssertNil(CloudStream.knownSize(of: unknown))
        let known = ArchiveItem(id: "2", name: "b.heic", source: .photo("p", expected: nil), size: 1_234)
        XCTAssertEqual(CloudStream.knownSize(of: known), 1_234)
    }

    // MARK: - Resuming OneDrive (1.0.2, D5)

    func testReadsWhereOneDriveWantsToCarryOn() {
        XCTAssertEqual(UploadRetry.oneDriveNext(Data(#"{"expirationDateTime":"2026-11-28T10:00:00Z","nextExpectedRanges":["26214400-"]}"#.utf8)), 26_214_400)
        XCTAssertEqual(UploadRetry.oneDriveNext(Data(#"{"nextExpectedRanges":["12345-55555","60000-"]}"#.utf8)), 12_345,
                       "The first gap is where it carries on.")
        XCTAssertNil(UploadRetry.oneDriveNext(Data(#"{"nextExpectedRanges":[]}"#.utf8)))
        XCTAssertNil(UploadRetry.oneDriveNext(Data(#"{"id":"item"}"#.utf8)))
        XCTAssertNil(UploadRetry.oneDriveNext(Data("not json".utf8)))
    }

    func testOnlyBusyAnswersAreRetried() {
        for status in [408, 429, 500, 502, 503, 504] { XCTAssertTrue(UploadRetry.transient(status), "\(status)") }
        for status in [200, 202, 400, 401, 403, 404, 409, 413, 416] { XCTAssertFalse(UploadRetry.transient(status), "\(status)") }
    }
}
