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
}
