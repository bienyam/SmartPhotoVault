import XCTest
@testable import SmartPhotoVault

final class SmartProTests: XCTestCase {
    // MARK: Screenshots

    private let now = ISO8601DateFormatter().date(from: "2026-12-03T12:00:00Z")!

    func testLoginCodes() {
        XCTAssertEqual(ScreenshotClassifier.classify("Your verification code is 482913. Don't share it.", now: now), .loginCode)
        XCTAssertEqual(ScreenshotClassifier.classify("G-583201 is your Google verification code", now: now), .loginCode)
        XCTAssertEqual(ScreenshotClassifier.classify("Use code 7741 to sign in\n9:41", now: now), .loginCode)
    }

    func testATimeIsNotACode() {
        XCTAssertNotEqual(ScreenshotClassifier.classify("Your code expires at 10:45", now: now), .loginCode)
    }

    func testExpiredTicketsNeedAPastDate() {
        let old = "BOARDING PASS\nFlight UA 512\nGate B12 Seat 14C\nOct 12, 2026"
        XCTAssertEqual(ScreenshotClassifier.classify(old, now: now), .expiredPass)
        let coming = "BOARDING PASS\nFlight UA 512\nGate B12 Seat 14C\nJan 20, 2027"
        XCTAssertNotEqual(ScreenshotClassifier.classify(coming, now: now), .expiredPass)
        XCTAssertEqual(ScreenshotClassifier.classify("Concert ticket\nAdmit One\nSection 104 Row F\nSeptember 5, 2026", now: now), .expiredPass)
    }

    func testReceipts() {
        XCTAssertEqual(ScreenshotClassifier.classify("Order #1182\nSubtotal $42.10\nTax $3.37\nTotal $45.47\nVisa ending 4021", now: now), .receipt)
        XCTAssertNotEqual(ScreenshotClassifier.classify("Total chaos at the party lol", now: now), .receipt, "Needs an amount too.")
    }

    func testMapsAndChats() {
        XCTAssertEqual(ScreenshotClassifier.classify("Directions\n12 min (3.1 mi)\nFastest route now due to traffic", now: now), .map)
        XCTAssertEqual(ScreenshotClassifier.classify("iMessage\nToday 9:41 AM\nsee you there!\nDelivered", now: now), .chat)
        XCTAssertEqual(ScreenshotClassifier.classify("ok 8:02 PM\nsure 8:05 PM\nomw 8:11 PM", now: now), .chat)
        XCTAssertEqual(ScreenshotClassifier.classify("Settings General About", now: now), .other)
        XCTAssertEqual(ScreenshotClassifier.classify("", now: now), .other)
    }

    // MARK: Best shot

    func testEyesOpenBeatsSharper() {
        let scores = [
            ShotScore(id: "a", sharpness: 90, faces: 2, eyesOpen: 1, faceQuality: 0.6),
            ShotScore(id: "b", sharpness: 70, faces: 2, eyesOpen: 2, faceQuality: 0.5)
        ]
        let pick = BestShot.pick(scores)
        XCTAssertEqual(pick?.id, "b")
        XCTAssertEqual(pick?.reason, "everyone's eyes open")
    }

    func testClearestFaceThenSharpest() {
        let scores = [
            ShotScore(id: "a", sharpness: 60, faces: 1, eyesOpen: 1, faceQuality: 0.4),
            ShotScore(id: "b", sharpness: 80, faces: 1, eyesOpen: 1, faceQuality: 0.7)
        ]
        let pick = BestShot.pick(scores)
        XCTAssertEqual(pick?.id, "b")
        XCTAssertEqual(pick?.reason, "sharpest, eyes open, clearest face")
    }

    func testWithoutFacesTheSharpestStays() {
        let scores = [ShotScore(id: "a", sharpness: 30), ShotScore(id: "b", sharpness: 55), ShotScore(id: "c", sharpness: 41)]
        XCTAssertEqual(BestShot.pick(scores)?.id, "b")
        XCTAssertEqual(BestShot.pick(scores)?.reason, "sharpest")
        XCTAssertNil(BestShot.pick([]))
    }

    func testEyeOpenness() {
        let open = [CGPoint(x: 0, y: 0.5), CGPoint(x: 0.5, y: 0.35), CGPoint(x: 1, y: 0.5), CGPoint(x: 0.5, y: 0.65)]
        let closed = [CGPoint(x: 0, y: 0.5), CGPoint(x: 0.5, y: 0.47), CGPoint(x: 1, y: 0.5), CGPoint(x: 0.5, y: 0.53)]
        XCTAssertGreaterThan(BestShot.openness(open), BestShot.openEye)
        XCTAssertLessThan(BestShot.openness(closed), BestShot.openEye)
        XCTAssertEqual(BestShot.openness([]), 0)
    }

    // MARK: Already archived

    private func record(_ id: String, photo: String?, place: String, cloud: CloudService? = nil, bytes: Int64 = 100,
                        date: TimeInterval = 0, drive: String? = nil) -> ArchivedRecord {
        ArchivedRecord(id: id, name: "\(id).jpg", folderName: place, bytes: bytes, digest: "d", date: Date(timeIntervalSince1970: date),
                       viaHomeServer: false, folderBookmark: nil, driveFileID: drive, photoID: photo, cloud: cloud)
    }

    func testOnlyPhotosStillOnThePhoneCountOncePerPlace() {
        let records = [
            record("1", photo: "p1", place: "TidyAway", cloud: .oneDrive, date: 1),
            record("2", photo: "p1", place: "TidyAway", cloud: .oneDrive, date: 5),
            record("3", photo: "p2", place: "Backup", bytes: 500),
            record("4", photo: "gone", place: "Backup"),
            record("5", photo: nil, place: "Backup"),
            record("6", photo: "p3", place: "TidyAway Archive", drive: "abc")
        ]
        let places = ArchivedOnPhone.places(records: records, onPhone: ["p1", "p2", "p3"])
        XCTAssertEqual(places.map(\.place), ["Backup", "Google Drive", "OneDrive"])
        XCTAssertEqual(places.last?.records.map(\.id), ["2"], "The latest copy of a photo at a place is used.")
        XCTAssertEqual(places.first?.records.map(\.id), ["3"], "Photos no longer on the phone and files are left out.")
    }

    func testCompletionHandsEveryCopyToTheRemovalChecks() {
        let place = ArchivedPlace(place: "OneDrive", records: [record("1", photo: "p1", place: "x", cloud: .oneDrive),
                                                               record("2", photo: "p2", place: "x", cloud: .oneDrive)])
        let done = ArchivedOnPhone.completion(for: place)
        XCTAssertEqual(done.place, "OneDrive")
        XCTAssertEqual(done.photoIDs.sorted(), ["p1", "p2"])
        XCTAssertEqual(Set(done.copies.keys), Set(done.items.map(\.id)), "Every item has its saved copy, so each is proved before removal.")
    }
}
