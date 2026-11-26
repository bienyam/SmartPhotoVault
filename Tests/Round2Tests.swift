import XCTest
import Photos
@testable import SmartPhotoVault

// 1.0.1 round 2: Receipts & documents detection, the "not backed up" check and the rating counter.

final class ReceiptsDetectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func photo(_ id: String, daysAgo: Double = 120, favorite: Bool = false) -> AssetRecord {
        AssetRecord(id: id, filename: "\(id).heic", mediaType: PHAssetMediaType.image.rawValue, favorite: favorite,
                    createdAt: now.addingTimeInterval(-daysAgo * 86_400),
                    resources: [ResourceFingerprint(type: PHAssetResourceType.photo.rawValue, digest: id, bytes: 1_000)],
                    issue: nil, isScreenshot: false, albumIDs: [])
    }

    private func insight(_ id: String, labels: [String], face: Bool? = false, closeFace: Bool = false) -> PhotoInsight {
        var value = PhotoInsight(id: id)
        value.sharpness = 500
        value.brightness = 120
        value.labels = labels
        value.anyFace = face
        value.closeFace = closeFace
        return value
    }

    private func receipts(_ assets: [AssetRecord], _ insights: [String: PhotoInsight]) -> CleanupGroup? {
        let snapshot = ScanSnapshot(date: now, limitedAccess: false, includedCloudDownloads: false, assets: assets)
        return CleanupGrouper.groups(in: snapshot, insights: insights, facts: [:], now: now).first { $0.id == "expired" }
    }

    func testAPaperLabelIsRequired() {
        for label in ["receipt", "document", "printed_page", "checkbook"] {
            XCTAssertTrue(CleanupGrouper.isPaperwork(labels: [label], hasFace: false), label)
        }
        XCTAssertFalse(CleanupGrouper.isPaperwork(labels: [], hasFace: false))
        XCTAssertFalse(CleanupGrouper.isPaperwork(labels: ["beach", "food"], hasFace: false))
        XCTAssertEqual(CleanupGrouper.paperLabels, ["receipt", "document", "printed_page", "checkbook"])
    }

    func testATicketCountsOnlyTogetherWithAPaperLabel() {
        XCTAssertFalse(CleanupGrouper.isPaperwork(labels: ["ticket"], hasFace: false), "A ticket alone is a venue as often as a paper.")
        XCTAssertFalse(CleanupGrouper.isPaperwork(labels: ["ticket", "stadium"], hasFace: false))
        XCTAssertTrue(CleanupGrouper.isPaperwork(labels: ["ticket", "printed_page"], hasFace: false))
        XCTAssertEqual(CleanupGrouper.paperworkReasons(["ticket"]), [])
        XCTAssertEqual(CleanupGrouper.paperworkReasons(["ticket", "receipt", "beach"]), ["ticket", "receipt"])
        XCTAssertFalse(CleanupGrouper.paperLabels.contains("ticket"))
    }

    func testParkingLotsAndNumberPlatesAreDropped() {
        XCTAssertFalse(CleanupGrouper.isPaperwork(labels: ["parking_lot"], hasFace: false))
        XCTAssertFalse(CleanupGrouper.isPaperwork(labels: ["license_plate"], hasFace: false))
        XCTAssertFalse(CleanupGrouper.isPaperwork(labels: ["parking_lot", "license_plate", "ticket"], hasFace: false))
        XCTAssertTrue(CleanupGrouper.paperLabels.isDisjoint(with: ["parking_lot", "license_plate"]))
        XCTAssertEqual(CleanupGrouper.paperworkReasons(["parking_lot", "license_plate"]), [])
    }

    func testAnyFaceKeepsAPhotoOut() {
        XCTAssertFalse(CleanupGrouper.isPaperwork(labels: ["receipt"], hasFace: true))
        XCTAssertFalse(CleanupGrouper.isPaperwork(labels: ["receipt"], hasFace: nil), "Not checked for faces yet: left out.")
        XCTAssertEqual(insight("a", labels: ["receipt"], face: nil, closeFace: true).hasFace, true, "A close face is a face.")
        XCTAssertEqual(insight("a", labels: ["receipt"], face: true).hasFace, true, "A small face in the background counts too.")
        XCTAssertEqual(insight("a", labels: ["receipt"], face: false).hasFace, false)
        XCTAssertNil(insight("a", labels: ["receipt"], face: nil).hasFace)
    }

    func testResultsSavedBeforeTheFaceCheckStillLoad() throws {
        let saved = Data(#"{"id":"a","version":2,"labels":["receipt"],"sharpness":12,"closeFace":false}"#.utf8)
        let old = try JSONDecoder().decode(PhotoInsight.self, from: saved)
        XCTAssertNil(old.anyFace)
        XCTAssertNil(old.hasFace)
        XCTAssertFalse(CleanupGrouper.isPaperwork(labels: old.labels, hasFace: old.hasFace), "Stays out until it has been checked.")
        var checked = old
        checked.anyFace = false
        let again = try JSONDecoder().decode(PhotoInsight.self, from: JSONEncoder().encode(checked))
        XCTAssertEqual(again.anyFace, false)
        XCTAssertTrue(CleanupGrouper.isPaperwork(labels: again.labels, hasFace: again.hasFace))
    }

    func testTheGroupAppliesEveryRuleTogether() {
        let papers = ["receipt", "document", "printed_page", "checkbook"].enumerated().map { photo("paper\($0.offset)") }
        let withTicket = photo("stub")
        let personByCar = photo("person")
        let smallFace = photo("smallface")
        let concert = photo("concert")
        let parking = photo("parking")
        let plate = photo("plate")
        let fresh = photo("fresh", daysAgo: 30)
        let favorite = photo("favorite", favorite: true)
        let unchecked = photo("unchecked")
        var insights: [String: PhotoInsight] = [:]
        for (index, label) in ["receipt", "document", "printed_page", "checkbook"].enumerated() {
            insights["paper\(index)"] = insight("paper\(index)", labels: [label])
        }
        insights["stub"] = insight("stub", labels: ["ticket", "receipt"])
        insights["person"] = insight("person", labels: ["receipt"], face: true, closeFace: true)
        insights["smallface"] = insight("smallface", labels: ["document"], face: true)
        insights["concert"] = insight("concert", labels: ["ticket"])
        insights["parking"] = insight("parking", labels: ["parking_lot"])
        insights["plate"] = insight("plate", labels: ["license_plate"])
        insights["fresh"] = insight("fresh", labels: ["receipt"])
        insights["favorite"] = insight("favorite", labels: ["receipt"])
        insights["unchecked"] = insight("unchecked", labels: ["receipt"], face: nil)
        let group = receipts(papers + [withTicket, personByCar, smallFace, concert, parking, plate, fresh, favorite, unchecked], insights)
        XCTAssertEqual(Set(group?.items.map(\.id) ?? []), ["paper0", "paper1", "paper2", "paper3", "stub"])
    }

    func testTheThreeMonthRuleIsKept() {
        let old = (0..<3).map { photo("old\($0)", daysAgo: 91) }
        let recent = (0..<3).map { photo("new\($0)", daysAgo: 89) }
        let insights = Dictionary(uniqueKeysWithValues: (old + recent).map { ($0.id, insight($0.id, labels: ["receipt"])) })
        XCTAssertEqual(Set(receipts(old + recent, insights)?.items.map(\.id) ?? []), Set(old.map(\.id)))
        XCTAssertEqual(CleanupGrouper.receiptAge, 90 * 86_400)
    }

    /// Check-in history and the Pro gate are keyed by the group's id, so only the name changed.
    func testTheGroupIsRenamedButKeepsItsStoredId() {
        let photos = (0..<3).map { photo("r\($0)") }
        let insights = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, insight($0.id, labels: ["receipt"])) })
        let group = receipts(photos, insights)
        XCTAssertEqual(group?.id, "expired")
        XCTAssertEqual(group?.title, "Receipts & documents")
        XCTAssertEqual(group?.why, "Over 3 months old")
        XCTAssertFalse(group?.info.contains("parking") ?? true)
        XCTAssertTrue(group?.info.contains("face") ?? false)
        XCTAssertEqual(ProGate.reportFeature("expired"), .smartPicks)
        XCTAssertTrue(ProGate.smartPickWhat("expired").contains("receipts and documents"))
        XCTAssertFalse(ProGate.smartPickWhat("expired").contains("parking"))
        XCTAssertFalse(ProGate.allows(.smartPicks, pro: false, grandfathered: false), "Still a Pro smart pick.")
    }
}

final class BackupCheckTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func video(_ id: String, bytes: Int64 = 100) -> AssetRecord {
        AssetRecord(id: id, filename: "\(id).mov", mediaType: PHAssetMediaType.video.rawValue, favorite: false,
                    createdAt: now,
                    resources: [ResourceFingerprint(type: PHAssetResourceType.video.rawValue, digest: id, bytes: bytes)],
                    issue: nil, isScreenshot: false, albumIDs: [])
    }

    private func record(_ id: String, photo: String?, parts: [Int] = [], date: Date? = nil) -> ArchivedRecord {
        let others = parts.map { ArchivedPart(type: $0, name: "\(id)-\($0)", bytes: 10, digest: "p\($0)") }
        return ArchivedRecord(id: id, name: "\(id).mov", folderName: "Drive", bytes: 100, digest: "d-\(id)", date: date ?? now,
                              viaHomeServer: false, folderBookmark: nil, photoID: photo, parts: others.isEmpty ? nil : others)
    }

    /// One original file, last changed an hour before the copy was recorded.
    private var untouched: OriginalNow { OriginalNow(single: true, parts: nil, modified: now.addingTimeInterval(-3_600)) }
    private let edit = [ArchivePlan.adjustmentData, ArchivePlan.fullSizePhoto]

    func testCountsBackedUpAndNotBackedUpWithTheSizeAtRisk() {
        let selected = (0..<14).map { video("v\($0)", bytes: Int64(100 + $0)) }
        let check = BackupCheck(selected: selected, archived: ["v0", "v5", "not-selected"])
        XCTAssertEqual(check.backedUp.map(\.id), ["v0", "v5"])
        XCTAssertEqual(check.notBackedUp.count, 12)
        XCTAssertEqual(check.total, 14)
        XCTAssertEqual(check.notBackedUpBytes, selected.reduce(0) { $0 + $1.displayBytes } - 100 - 105)
        XCTAssertTrue(check.needsAlert)
        XCTAssertEqual(check.title, "12 of these aren't backed up")
        XCTAssertEqual(check.backedUpLine, "2 backed up")
        XCTAssertEqual(check.notBackedUpLine, "12 not backed up")
        XCTAssertEqual(check.message, "Once deleted and Recently Deleted is emptied, they're gone. Copy them first?")
    }

    func testNoAlertWhenEverySelectedItemHasAVerifiedCopy() {
        let selected = [video("a"), video("b")]
        let check = BackupCheck(selected: selected, archived: ["a", "b"])
        XCTAssertFalse(check.needsAlert)
        XCTAssertNil(BackupCheck.alert(for: .list, selected: selected, archived: ["a", "b"]))
        XCTAssertNil(BackupCheck.alert(for: .list, selected: [], archived: []), "Nothing selected, nothing to ask.")
    }

    func testTheAlertShowsEvenWhenOnlyOneItemHasNoCopy() {
        let check = BackupCheck.alert(for: .list, selected: [video("a"), video("b"), video("c")], archived: ["a", "b"])
        XCTAssertEqual(check?.notBackedUp.map(\.id), ["c"])
        XCTAssertEqual(check?.title, "1 of these isn't backed up")
        XCTAssertEqual(check?.message, "Once deleted and Recently Deleted is emptied, it's gone. Copy it first?")
        XCTAssertEqual(BackupCheck(selected: [video("z")], archived: []).title, "This one isn't backed up")
    }

    func testDuplicatesAndAlreadyArchivedSkipTheCheck() {
        let selected = [video("a"), video("b")]
        XCTAssertNil(BackupCheck.alert(for: .duplicates, selected: selected, archived: []), "The kept copy stays, so nothing is lost.")
        XCTAssertNil(BackupCheck.alert(for: .alreadyArchived, selected: selected, archived: []))
        XCTAssertNotNil(BackupCheck.alert(for: .list, selected: selected, archived: []))
        XCTAssertEqual(DeleteFlow.allCases.filter(\.checksBackup), [.list], "Only these two kinds of delete skip it.")
    }

    func testOnlyAVerifiedArchiveRecordCounts() {
        // An original kept only in iCloud is not "backed up": deleting it from Photos deletes it from iCloud too.
        let inICloud = AssetRecord(id: "cloud", filename: "cloud.mov", mediaType: PHAssetMediaType.video.rawValue, favorite: false,
                                   createdAt: now, resources: [], issue: "Original resource is not available locally.",
                                   isScreenshot: false, albumIDs: [], cloudBytes: 5_000)
        XCTAssertTrue(inICloud.inICloud)
        let check = BackupCheck.alert(for: .list, selected: [inICloud], archived: [])
        XCTAssertEqual(check?.notBackedUp.map(\.id), ["cloud"])
        XCTAssertEqual(check?.notBackedUpBytes, 5_000)
    }

    func testTheLedgerReadsPhotoIdentifiersFromArchiveRecords() {
        let records = [record("r1", photo: "p1"), record("r2", photo: "p1"), record("r3", photo: "p2"), record("r4", photo: nil)]
        let photos = ["p1": untouched, "p2": untouched, "p3": untouched]
        XCTAssertEqual(BackupLedger.photoIDs(in: records, now: photos), ["p1", "p2"],
                       "A file archived from Files has no photo, so it backs nothing up.")
        XCTAssertEqual(BackupLedger.photoIDs(in: [], now: photos), [])
        XCTAssertEqual(BackupLedger.photoIDs(in: records, now: [:]), [], "An original Photos can't describe is not backed up.")
        let check = BackupCheck(selected: [video("p1"), video("p3")], archived: BackupLedger.photoIDs(in: records, now: photos))
        XCTAssertEqual(check.backedUp.map(\.id), ["p1"])
        XCTAssertEqual(check.notBackedUp.map(\.id), ["p3"])
    }

    /// The copy of a photo edited after it was archived doesn't hold the edit, so deleting the photo
    /// would lose it. It must be counted as not backed up, and the alert must show.
    func testAPhotoEditedAfterItWasArchivedIsNotBackedUp() {
        let before = now.addingTimeInterval(-60)
        let later = now.addingTimeInterval(60)
        let kinds = [ArchivePlan.photo] + edit
        // A single-file copy: the first edit adds files beside the original.
        let single = record("r1", photo: "p")
        XCTAssertTrue(BackupLedger.covers(single, untouched))
        XCTAssertTrue(BackupLedger.covers(single, OriginalNow(single: true, parts: nil, modified: now)))
        XCTAssertFalse(BackupLedger.covers(single, OriginalNow(single: false, parts: kinds, modified: later)),
                       "Edited after the copy: more files than were copied.")
        XCTAssertFalse(BackupLedger.covers(single, OriginalNow(single: false, parts: kinds, modified: before)),
                       "The kinds of files decide on their own, whatever the date says.")
        XCTAssertFalse(BackupLedger.covers(single, OriginalNow(single: true, parts: nil, modified: later)),
                       "Changed since the copy was recorded.")
        XCTAssertFalse(BackupLedger.covers(single, OriginalNow(single: true, parts: nil, modified: nil)),
                       "No date from Photos: can't tell, so not backed up.")

        // An edited photo, copied with its edit: a second edit keeps the kinds and moves the date.
        let edited = record("r2", photo: "p", parts: edit)
        XCTAssertEqual(edited.partTypes, kinds)
        XCTAssertTrue(BackupLedger.covers(edited, OriginalNow(single: false, parts: kinds, modified: before)))
        XCTAssertFalse(BackupLedger.covers(edited, OriginalNow(single: false, parts: kinds, modified: later)), "Edited again after the copy.")
        XCTAssertFalse(BackupLedger.covers(edited, OriginalNow(single: true, parts: nil, modified: before)),
                       "Reverted: no longer the files that were copied.")
        XCTAssertFalse(BackupLedger.covers(edited, OriginalNow(single: false, parts: kinds + [ArchivePlan.fullSizePairedVideo], modified: before)))

        // Through the whole check: the edited photo is at risk, so the alert shows and counts it.
        let inPhotos = ["kept": untouched, "changed": OriginalNow(single: false, parts: kinds, modified: later)]
        let records = [record("a", photo: "kept"), record("b", photo: "changed")]
        let archived = BackupLedger.photoIDs(in: records, now: inPhotos)
        XCTAssertEqual(archived, ["kept"])
        let check = BackupCheck.alert(for: .list, selected: [video("kept"), video("changed")], archived: archived)
        XCTAssertEqual(check?.notBackedUp.map(\.id), ["changed"])
        XCTAssertEqual(check?.backedUp.map(\.id), ["kept"])
        XCTAssertEqual(check?.title, "1 of these isn't backed up")
    }

    /// Copied again after the edit: the newer record covers the photo even though the older one doesn't.
    func testAPhotoCopiedAgainAfterAnEditIsBackedUp() {
        let kinds = [ArchivePlan.photo] + edit
        let old = record("old", photo: "p")
        let fresh = record("fresh", photo: "p", parts: edit, date: now.addingTimeInterval(120))
        let state = ["p": OriginalNow(single: false, parts: kinds, modified: now.addingTimeInterval(60))]
        XCTAssertEqual(BackupLedger.photoIDs(in: [old], now: state), [])
        XCTAssertEqual(BackupLedger.photoIDs(in: [fresh, old], now: state), ["p"])
    }
}

final class RatingPromptTests: XCTestCase {
    private var suite = ""
    private var store: UserDefaults!

    override func setUp() {
        suite = "rating-tests-\(UUID().uuidString)"
        store = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suite)
    }

    func testNotAskedBeforeTheSecondCompletion() {
        XCTAssertFalse(RatingPrompt.takeDue(store: store))
        RatingPrompt.noteCompletion(store: store)
        XCTAssertEqual(RatingPrompt.completions(store: store), 1)
        XCTAssertFalse(RatingPrompt.takeDue(store: store), "One cleanup is not enough.")
    }

    func testAskedOnceAfterTheSecondCompletion() {
        RatingPrompt.noteCompletion(store: store)
        RatingPrompt.noteCompletion(store: store)
        XCTAssertEqual(RatingPrompt.completions(store: store), 2)
        XCTAssertTrue(RatingPrompt.takeDue(store: store))
        XCTAssertFalse(RatingPrompt.takeDue(store: store), "Asked once.")
        RatingPrompt.noteCompletion(store: store)
        XCTAssertFalse(RatingPrompt.takeDue(store: store), "Later cleanups don't ask again.")
    }

    func testTheCountIsKeptBetweenLaunches() {
        RatingPrompt.noteCompletion(store: store)
        let later = UserDefaults(suiteName: suite)!
        XCTAssertEqual(RatingPrompt.completions(store: later), 1)
        RatingPrompt.noteCompletion(store: later)
        XCTAssertTrue(RatingPrompt.takeDue(store: later))
        XCTAssertFalse(RatingPrompt.takeDue(store: UserDefaults(suiteName: suite)!), "That it was asked is kept too.")
    }

    func testACompletionNotedWhileAnotherScreenIsUpIsAskedLater() {
        // The count can pass two before a result screen closes (an archive, then deleting the originals).
        for _ in 0..<3 { RatingPrompt.noteCompletion(store: store) }
        XCTAssertTrue(RatingPrompt.takeDue(store: store))
        XCTAssertFalse(RatingPrompt.takeDue(store: store))
    }
}
