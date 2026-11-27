import XCTest
import SwiftUI
import Photos
@testable import SmartPhotoVault

/// 1.0.2 polish: confetti, Appearance wording, thumbnails and sizes taken from the scene, not UIScreen.
@MainActor
final class Release102PolishTests: XCTestCase {
    func testConfettiRespectsReduceMotionAndStops() {
        XCTAssertFalse(ConfettiBurst.plays(reduceMotion: true), "Reduce Motion: no confetti.")
        XCTAssertTrue(ConfettiBurst.plays(reduceMotion: false))
        XCTAssertEqual(ConfettiBurst.lifetime, 4, "The timeline stops after 4 seconds.")
    }

    func testAppearanceFollowsTheDeviceName() {
        XCTAssertEqual(AppearanceChoice.system.title, "Same as \(Device.name)")
        XCTAssertEqual(AppearanceChoice.light.title, "Light")
        XCTAssertEqual(AppearanceChoice.dark.title, "Dark")
    }

    func testThumbnailsShareOneCachingManager() async {
        XCTAssertTrue(Thumbnails.manager === Thumbnails.manager)
        let missing = await Thumbnails.asset("not-a-real-asset/L0/001")
        XCTAssertNil(missing)
    }

    func testPreviewSizeComesFromThePage() {
        XCTAssertEqual(PreviewLoader.side(for: CGSize(width: 390, height: 844), scale: 3), 3_000, "Capped.")
        XCTAssertEqual(PreviewLoader.side(for: CGSize(width: 300, height: 400), scale: 2), 1_200)
        XCTAssertEqual(PreviewLoader.side(for: .zero, scale: 2), 2_700, "Before layout: a phone-sized request.")
    }

    func testSkimCountsACellOnlyInsideTheVisibleArea() {
        let bottom: CGFloat = 800
        XCTAssertTrue(GroupSkimView.isShown(CGRect(x: 0, y: 200, width: 90, height: 90), viewportBottom: bottom))
        XCTAssertFalse(GroupSkimView.isShown(CGRect(x: 0, y: 20, width: 90, height: 90), viewportBottom: bottom), "Under the top bar.")
        XCTAssertFalse(GroupSkimView.isShown(CGRect(x: 0, y: 600, width: 90, height: 90), viewportBottom: bottom), "Under the bottom bar.")
        XCTAssertFalse(GroupSkimView.isShown(CGRect(x: 0, y: 200, width: 90, height: 90), viewportBottom: 0), "Not measured yet.")
    }
}
