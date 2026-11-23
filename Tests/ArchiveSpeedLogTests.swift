import XCTest
@testable import SmartPhotoVault

@MainActor
final class ArchiveSpeedLogTests: XCTestCase {
    func testThroughputSaysHowMuchAndHowFast() {
        let start = Date(timeIntervalSince1970: 0)
        let line = PhotoArchiveView.throughput(100_000_000, since: start, now: start.addingTimeInterval(10))
        XCTAssertTrue(line.contains("at "), line)
        XCTAssertTrue(line.hasSuffix("/s"), line)
        XCTAssertTrue(line.contains("10 MB/s"), line)
    }

    func testAnInstantCopyDoesNotDivideByZero() {
        let start = Date()
        XCTAssertTrue(PhotoArchiveView.throughput(0, since: start, now: start).hasSuffix("/s"))
    }
}
