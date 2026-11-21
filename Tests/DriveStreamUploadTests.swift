import CryptoKit
import XCTest
@testable import SmartPhotoVault

final class DriveStreamUploadTests: XCTestCase {
    /// A fake upload session that records each piece and answers like Google Drive.
    private final class FakeDrive: @unchecked Sendable {
        var ranges: [String] = []
        var received = Data()
        var corrupt = false

        func handle(_ body: Data, _ range: String) -> (status: Int, body: Data) {
            ranges.append(range)
            received.append(body)
            guard range.hasSuffix("/*") == false else { return (308, Data()) }
            let stored = corrupt ? received + Data([0]) : received
            let sha = SHA256.hash(data: stored).map { String(format: "%02x", $0) }.joined()
            let json = #"{"id":"file-1","sha256Checksum":"\#(sha)"}"#
            return (200, Data(json.utf8))
        }
    }

    func testContentRangeHeaders() {
        XCTAssertEqual(DriveStreamUpload.contentRange(start: 0, count: 10, total: nil), "bytes 0-9/*")
        XCTAssertEqual(DriveStreamUpload.contentRange(start: 10, count: 5, total: 15), "bytes 10-14/15")
        XCTAssertEqual(DriveStreamUpload.contentRange(start: 15, count: 0, total: 15), "bytes */15")
    }

    func testPieceSizeIsAMultipleOf256KiB() {
        XCTAssertEqual(DriveStreamUpload.pieceSize % (256 * 1024), 0)
        XCTAssertEqual(DriveStreamUpload.pieceSize, 8 * 1024 * 1024)
    }

    func testStreamsInPiecesWithoutHoldingTheWholeFile() throws {
        let drive = FakeDrive()
        let upload = DriveStreamUpload { body, range in drive.handle(body, range) }
        let piece = DriveStreamUpload.pieceSize
        var original = Data()
        // Arrives in uneven chunks, like Photos delivers a download.
        for size in [3_000_000, 7_000_000, 9_000_000, 1_500_000] {
            let chunk = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
            original.append(chunk)
            upload.append(chunk)
        }
        let result = try upload.finish()
        XCTAssertEqual(result.file.id, "file-1")
        XCTAssertEqual(drive.received, original, "Every byte reached Drive, in order.")
        XCTAssertEqual(result.fingerprint.bytes, Int64(original.count))
        XCTAssertEqual(drive.ranges.count, 3, "Two full pieces, then the rest as the last piece.")
        XCTAssertEqual(drive.ranges[0], "bytes 0-\(piece - 1)/*")
        XCTAssertEqual(drive.ranges[1], "bytes \(piece)-\(2 * piece - 1)/*")
        XCTAssertEqual(drive.ranges[2], "bytes \(2 * piece)-\(original.count - 1)/\(original.count)")
    }

    func testAChecksumMismatchIsNotCountedAsArchived() {
        let drive = FakeDrive()
        drive.corrupt = true
        let upload = DriveStreamUpload { body, range in drive.handle(body, range) }
        upload.append(Data("hello".utf8))
        XCTAssertThrowsError(try upload.finish()) { error in
            XCTAssertEqual(error as? GoogleDriveError, .verification)
        }
    }

    func testADownloadFailureStopsTheUpload() {
        let drive = FakeDrive()
        let upload = DriveStreamUpload { body, range in drive.handle(body, range) }
        upload.append(Data("partial".utf8))
        upload.fail(ArchiveError.iCloudDownload)
        XCTAssertThrowsError(try upload.finish())
        XCTAssertTrue(drive.ranges.isEmpty, "Nothing is finalised in Drive after a failed download.")
    }
}
