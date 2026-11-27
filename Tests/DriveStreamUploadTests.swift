import CryptoKit
import XCTest
@testable import SmartPhotoVault

final class DriveStreamUploadTests: XCTestCase {
    /// A fake upload session that records each piece and answers like Google Drive.
    private final class FakeDrive: @unchecked Sendable {
        var ranges: [String] = []
        var received = Data()
        var corrupt = false

        func handle(_ body: Data, _ range: String) -> DriveStreamUpload.Reply {
            ranges.append(range)
            received.append(body)
            guard range.hasSuffix("/*") == false else {
                return DriveStreamUpload.Reply(status: 308, body: Data(), range: "bytes=0-\(received.count - 1)")
            }
            let stored = corrupt ? received + Data([0]) : received
            let sha = SHA256.hash(data: stored).map { String(format: "%02x", $0) }.joined()
            let json = #"{"id":"file-1","sha256Checksum":"\#(sha)"}"#
            return DriveStreamUpload.Reply(status: 200, body: Data(json.utf8))
        }
    }

    /// A fake upload session that keeps what it is really sent, the way Drive does: it can keep only
    /// part of a piece, or drop the connection partway, and it answers status questions.
    private final class ResumableDrive: @unchecked Sendable {
        var stored = Data()
        var ranges: [String] = []
        /// Each piece must start exactly where Drive's copy ends.
        var misaligned = false
        /// Keeps at most this many bytes of the next piece, once.
        var keepAtMost: Int?
        /// On these calls (counted from 0) the connection drops after `keepOnDrop` bytes arrived.
        var dropAt: Set<Int> = []
        var keepOnDrop = 0

        func handle(_ body: Data, _ range: String) throws -> DriveStreamUpload.Reply {
            let call = ranges.count
            ranges.append(range)
            let spec = range.dropFirst("bytes ".count).split(separator: "/")
            let total = spec[1] == "*" ? nil : Int(spec[1])
            if spec[0] != "*" {
                if Int(spec[0].split(separator: "-")[0]) != stored.count { misaligned = true }
                if dropAt.contains(call) {
                    stored.append(body.prefix(keepOnDrop))
                    throw URLError(.networkConnectionLost)
                }
                if let most = keepAtMost {
                    stored.append(body.prefix(most))
                    keepAtMost = nil
                } else {
                    stored.append(body)
                }
            }
            if let total, stored.count == total {
                let sha = SHA256.hash(data: stored).map { String(format: "%02x", $0) }.joined()
                return DriveStreamUpload.Reply(status: 200, body: Data(#"{"id":"file-2","sha256Checksum":"\#(sha)"}"#.utf8))
            }
            return DriveStreamUpload.Reply(status: 308, body: Data(), range: stored.isEmpty ? nil : "bytes=0-\(stored.count - 1)")
        }
    }

    private final class Pauses: @unchecked Sendable {
        var waited: [Int] = []
    }

    private final class Calls: @unchecked Sendable {
        var count = 0
    }

    private func sample(_ count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 37) })
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

    // MARK: - Resuming (1.0.2, D5)

    func testReadsHowMuchDriveHolds() throws {
        XCTAssertEqual(DriveStreamUpload.held(range: "bytes=0-1048575"), 1_048_576)
        XCTAssertEqual(DriveStreamUpload.held(range: "bytes=0-0"), 1)
        XCTAssertNil(DriveStreamUpload.held(range: "bytes=5-10"), "Drive always counts from the first byte.")
        XCTAssertNil(DriveStreamUpload.held(range: "nonsense"))
        XCTAssertEqual(try DriveStreamUpload.step(status: 308, range: nil), .holds(0), "No Range header: nothing kept yet.")
        XCTAssertEqual(try DriveStreamUpload.step(status: 308, range: "bytes=0-99"), .holds(100))
        XCTAssertEqual(try DriveStreamUpload.step(status: 200, range: nil), .finished)
        XCTAssertEqual(try DriveStreamUpload.step(status: 201, range: nil), .finished)
        XCTAssertThrowsError(try DriveStreamUpload.step(status: 503, range: nil)) { error in
            XCTAssertEqual(error as? GoogleDriveError, .server(503))
        }
    }

    func testWhatDriveDidntKeepIsSentAgain() throws {
        let drive = ResumableDrive()
        drive.keepAtMost = 1_000_000
        let pauses = Pauses()
        let upload = DriveStreamUpload(transport: { try drive.handle($0, $1) }, pause: { pauses.waited.append($0) })
        let original = sample(DriveStreamUpload.pieceSize * 2 + 500_000)
        upload.append(original)
        let result = try upload.finish()
        XCTAssertEqual(drive.stored, original, "Every byte reached Drive once, in order.")
        XCTAssertFalse(drive.misaligned)
        XCTAssertEqual(drive.ranges[1], "bytes 1000000-\(DriveStreamUpload.pieceSize - 1)/*", "The rest of the piece, from where Drive stopped.")
        XCTAssertEqual(result.fingerprint.bytes, Int64(original.count))
        XCTAssertEqual(result.file.id, "file-2")
        XCTAssertTrue(pauses.waited.isEmpty, "Progress isn't a failure; nothing waits.")
    }

    func testADroppedConnectionAsksDriveAndCarriesOn() throws {
        let drive = ResumableDrive()
        drive.dropAt = [1]
        drive.keepOnDrop = 3_000_000
        let pauses = Pauses()
        let upload = DriveStreamUpload(transport: { try drive.handle($0, $1) }, pause: { pauses.waited.append($0) })
        let original = sample(DriveStreamUpload.pieceSize * 2 + 123)
        upload.append(original)
        let result = try upload.finish()
        XCTAssertEqual(drive.stored, original)
        XCTAssertFalse(drive.misaligned)
        XCTAssertEqual(drive.ranges[2], "bytes */*", "After the drop it asks Drive how much it holds.")
        XCTAssertEqual(drive.ranges[3], "bytes \(DriveStreamUpload.pieceSize + 3_000_000)-\(2 * DriveStreamUpload.pieceSize - 1)/*")
        XCTAssertEqual(pauses.waited, [1])
        XCTAssertEqual(result.fingerprint.bytes, Int64(original.count))
    }

    func testADroppedLastPieceAsksWithTheTotal() throws {
        let drive = ResumableDrive()
        drive.dropAt = [0]
        drive.keepOnDrop = 10
        let upload = DriveStreamUpload(transport: { try drive.handle($0, $1) }, pause: { _ in })
        let original = sample(100)
        upload.append(original)
        _ = try upload.finish()
        XCTAssertEqual(drive.ranges, ["bytes 0-99/100", "bytes */100", "bytes 10-99/100"])
        XCTAssertEqual(drive.stored, original)
    }

    func testRetriesAreFewAndThenTheItemFails() {
        let calls = Calls()
        let pauses = Pauses()
        let upload = DriveStreamUpload(transport: { _, _ in
            calls.count += 1
            throw URLError(.notConnectedToInternet)
        }, pause: { pauses.waited.append($0) })
        upload.append(Data("hello".utf8))
        XCTAssertThrowsError(try upload.finish()) { error in
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        XCTAssertEqual(calls.count, 1 + UploadRetry.attempts)
        XCTAssertEqual(pauses.waited, Array(1...UploadRetry.attempts))
    }

    func testARefusalIsNotRetried() {
        let calls = Calls()
        let pauses = Pauses()
        let upload = DriveStreamUpload(transport: { _, _ in
            calls.count += 1
            return DriveStreamUpload.Reply(status: 404, body: Data())
        }, pause: { pauses.waited.append($0) })
        upload.append(Data("hello".utf8))
        XCTAssertThrowsError(try upload.finish()) { error in
            XCTAssertEqual(error as? GoogleDriveError, .server(404))
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(pauses.waited.isEmpty)
    }

    func testDriveKeepingNothingStopsAfterAFewTries() {
        let calls = Calls()
        let upload = DriveStreamUpload(transport: { _, _ in
            calls.count += 1
            return DriveStreamUpload.Reply(status: 308, body: Data())
        }, pause: { _ in })
        upload.append(sample(DriveStreamUpload.pieceSize))
        XCTAssertThrowsError(try upload.finish()) { error in
            XCTAssertEqual(error as? GoogleDriveError, .server(308))
        }
        XCTAssertEqual(calls.count, 1 + UploadRetry.attempts, "A session that never moves forward isn't tried forever.")
    }

    func testWhichFailuresAreRetried() {
        XCTAssertTrue(UploadRetry.retryable(URLError(.networkConnectionLost)))
        XCTAssertTrue(UploadRetry.retryable(URLError(.timedOut)))
        XCTAssertTrue(UploadRetry.retryable(GoogleDriveError.server(503)))
        XCTAssertTrue(UploadRetry.retryable(CloudError.server("OneDrive", 500)))
        XCTAssertFalse(UploadRetry.retryable(URLError(.cancelled)))
        XCTAssertFalse(UploadRetry.retryable(GoogleDriveError.server(404)))
        XCTAssertFalse(UploadRetry.retryable(GoogleDriveError.verification), "A checksum mismatch is never retried.")
        XCTAssertFalse(UploadRetry.retryable(ArchiveError.iCloudDownload))
        XCTAssertEqual((1...5).map(UploadRetry.delay), [1, 2, 4, 8, 8])
    }
}
