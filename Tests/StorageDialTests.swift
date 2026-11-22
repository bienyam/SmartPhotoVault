import SwiftUI
import XCTest
@testable import SmartPhotoVault

final class StorageDialTests: XCTestCase {
    func testArcsFollowEachOtherAndNeverPassAFullCircle() {
        let spans = DialPart.spans([DialPart(fraction: 0.2, color: .red), DialPart(fraction: 0.7, color: .gray)])
        XCTAssertEqual(spans[0].from, 0, accuracy: 0.0001)
        XCTAssertEqual(spans[0].to, 0.2, accuracy: 0.0001)
        XCTAssertEqual(spans[1].from, 0.2, accuracy: 0.0001)
        XCTAssertEqual(spans[1].to, 0.9, accuracy: 0.0001)
        let full = DialPart.spans([DialPart(fraction: 0.8, color: .red), DialPart(fraction: 0.8, color: .gray), DialPart(fraction: -1, color: .red)])
        XCTAssertEqual(full[1].to, 1, accuracy: 0.0001)
        XCTAssertEqual(full[2].to, 1, accuracy: 0.0001)
        XCTAssertTrue(DialPart.spans([]).isEmpty)
    }
}
