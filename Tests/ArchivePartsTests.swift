import Photos
import XCTest
@testable import SmartPhotoVault

/// Live Photos and edited photos are archived as every file Photos keeps for them. These tests cover
/// which combinations are taken, what each file is called, that an item counts only when every file
/// was copied, and that records saved before this still work.
final class ArchivePartsTests: XCTestCase {
    private let photo = PHAssetResourceType.photo.rawValue
    private let video = PHAssetResourceType.video.rawValue
    private let alternate = PHAssetResourceType.alternatePhoto.rawValue
    private let fullPhoto = PHAssetResourceType.fullSizePhoto.rawValue
    private let fullVideo = PHAssetResourceType.fullSizeVideo.rawValue
    private let adjustment = PHAssetResourceType.adjustmentData.rawValue
    private let basePhoto = PHAssetResourceType.adjustmentBasePhoto.rawValue
    private let paired = PHAssetResourceType.pairedVideo.rawValue
    private let fullPaired = PHAssetResourceType.fullSizePairedVideo.rawValue
    private let image = PHAssetMediaType.image.rawValue
    private let movie = PHAssetMediaType.video.rawValue

    // MARK: - Which files are copied

    func testPhotosNumbersItsFilesTheWayTheLedgerRecordsThem() {
        // These numbers are saved in the ledger, so they must never drift.
        XCTAssertEqual([photo, video, alternate, fullPhoto, fullVideo, adjustment, basePhoto, paired, fullPaired], [1, 2, 4, 5, 6, 7, 8, 9, 10])
    }

    func testLivePhotoIsItsStillAndItsVideo() {
        XCTAssertEqual(ArchivePlan.parts(mediaType: image, types: [photo, paired]), [photo, paired])
        XCTAssertEqual(ArchivePlan.parts(mediaType: image, types: [paired, photo]), [photo, paired], "The still always comes first.")
    }

    func testEditedPhotoIsItsOriginalItsEditAndTheEditedPicture() {
        XCTAssertEqual(ArchivePlan.parts(mediaType: image, types: [fullPhoto, adjustment, photo]), [photo, adjustment, fullPhoto])
    }

    func testEditedLivePhotoKeepsEveryFile() {
        XCTAssertEqual(ArchivePlan.parts(mediaType: image, types: [photo, paired, fullPhoto, fullPaired, adjustment]),
                       [photo, paired, adjustment, fullPhoto, fullPaired])
        XCTAssertEqual(ArchivePlan.parts(mediaType: image, types: [photo, paired, fullPhoto, adjustment]),
                       [photo, paired, adjustment, fullPhoto], "An edit that left the video alone has no edited video.")
    }

    func testSingleFilesDoNotComeThroughThePartsPlan() {
        XCTAssertNil(ArchivePlan.parts(mediaType: image, types: [photo]))
        XCTAssertNil(ArchivePlan.parts(mediaType: movie, types: [video]))
        XCTAssertNil(ArchivePlan.parts(mediaType: image, types: []))
    }

    func testCombinationsThatCannotBePutBackAreSkipped() {
        let skipped: [(String, Int, [Int])] = [
            ("slo-mo or edited video", movie, [video, adjustment]),
            ("edited video with its render", movie, [video, fullVideo, adjustment]),
            ("a video is never a Live Photo", movie, [photo, paired]),
            ("RAW + JPEG pair", image, [photo, alternate]),
            ("edited picture without its instructions", image, [photo, fullPhoto]),
            ("instructions without the edited picture", image, [photo, adjustment]),
            ("edited video without an edit", image, [photo, paired, fullPaired]),
            ("edited video without a Live Photo", image, [photo, fullPhoto, adjustment, fullPaired]),
            ("an edit kept on top of another render", image, [photo, basePhoto, fullPhoto, adjustment]),
            ("two files of one kind", image, [photo, photo, paired]),
            ("no original still", image, [paired, fullPhoto, adjustment]),
            ("a kind TidyAway doesn't know", image, [photo, paired, 19]),
        ]
        for (why, media, types) in skipped {
            XCTAssertNil(ArchivePlan.parts(mediaType: media, types: types), why)
        }
    }

    private func record(_ name: String, media: Int? = nil, types: [Int], subtypes: PHAssetMediaSubtype = [], issue: String? = nil) -> AssetRecord {
        AssetRecord(id: name, filename: name, mediaType: media ?? image, favorite: false, createdAt: nil,
                    resources: types.enumerated().map { ResourceFingerprint(type: $1, digest: "d\($0)", bytes: Int64(100 * ($0 + 1))) },
                    issue: issue, subtypes: subtypes.rawValue)
    }

    func testLiveAndEditedPhotosCanBeArchivedAndTheRestStillCannot() {
        XCTAssertTrue(SmartGrouper.canArchive(record("live.HEIC", types: [photo, paired], subtypes: .photoLive)))
        XCTAssertTrue(SmartGrouper.canArchive(record("edited.JPG", types: [photo, fullPhoto, adjustment])))
        XCTAssertTrue(SmartGrouper.canArchive(record("both.HEIC", types: [photo, paired, fullPhoto, fullPaired, adjustment], subtypes: .photoLive)))
        // Unchanged: single files.
        XCTAssertTrue(SmartGrouper.canArchive(record("plain.HEIC", types: [photo])))
        XCTAssertTrue(SmartGrouper.canArchive(record("clip.MOV", media: movie, types: [video])))
        // Still skipped.
        XCTAssertFalse(SmartGrouper.canArchive(record("slomo.MOV", media: movie, types: [video, adjustment], subtypes: .videoHighFrameRate)))
        XCTAssertFalse(SmartGrouper.canArchive(record("cut.MOV", media: movie, types: [video, fullVideo, adjustment])))
        XCTAssertFalse(SmartGrouper.canArchive(record("raw.JPG", types: [photo, alternate])))
        XCTAssertFalse(SmartGrouper.canArchive(record("shot.PNG", types: [photo, fullPhoto, adjustment])), "Only JPEG and HEIC, as before.")
        XCTAssertFalse(SmartGrouper.canArchive(record("half.HEIC", types: [photo, paired], subtypes: .photoLive, issue: "unreadable")))
        XCTAssertFalse(SmartGrouper.canArchive(record("odd.HEIC", types: [photo], subtypes: .photoLive)), "A Live Photo with no video isn't whole.")
    }

    func testLivePhotoStillInICloudIsOfferedAndCheckedWhenItIsCopied() {
        var cloud = AssetRecord(id: "c", filename: "c.HEIC", mediaType: image, favorite: false, createdAt: nil, resources: [],
                                issue: "Original resource is not available locally.", subtypes: PHAssetMediaSubtype.photoLive.rawValue)
        XCTAssertFalse(SmartGrouper.canArchive(cloud))
        cloud.cloudBytes = 5_000_000
        XCTAssertTrue(SmartGrouper.canArchive(cloud))
    }

    func testTheScanFingerprintOfEachFileIsTheOneItIsCheckedAgainst() {
        let single = record("plain.HEIC", types: [photo])
        XCTAssertEqual(ArchivePlan.primaryFingerprint(of: single), single.resources.first)
        XCTAssertNil(ArchivePlan.partFingerprints(of: single), "A single file is checked the way it always was.")
        let live = record("live.HEIC", types: [paired, photo], subtypes: .photoLive)
        XCTAssertEqual(ArchivePlan.primaryFingerprint(of: live)?.type, photo, "Never the video's fingerprint for the still.")
        XCTAssertEqual(ArchivePlan.partFingerprints(of: live)?.count, 2)
        XCTAssertNil(ArchivePlan.partFingerprints(of: record("raw.JPG", types: [photo, alternate])))
    }

    // MARK: - What each file is called

    func testFilesSitSideBySideUnderTheOriginalsName() {
        XCTAssertEqual(ArchivePlan.name(for: photo, primary: "IMG_1234.HEIC", resourceFilename: "IMG_1234.HEIC"), "IMG_1234.HEIC")
        XCTAssertEqual(ArchivePlan.name(for: paired, primary: "IMG_1234.HEIC", resourceFilename: "IMG_1234.MOV"), "IMG_1234.MOV")
        XCTAssertEqual(ArchivePlan.name(for: adjustment, primary: "IMG_1234.HEIC", resourceFilename: "Adjustments.plist"), "IMG_1234.AAE")
        XCTAssertEqual(ArchivePlan.name(for: fullPhoto, primary: "IMG_1234.HEIC", resourceFilename: "FullSizeRender.jpg"), "IMG_1234_edited.JPG")
        XCTAssertEqual(ArchivePlan.name(for: fullPaired, primary: "IMG_1234.HEIC", resourceFilename: "FullSizeRender.mov"), "IMG_1234_edited.MOV")
    }

    func testNamesFollowTheOriginalsCaseAndSurviveOddNames() {
        XCTAssertEqual(ArchivePlan.name(for: paired, primary: "holiday.heic", resourceFilename: "holiday.MOV"), "holiday.MOV")
        XCTAssertEqual(ArchivePlan.name(for: adjustment, primary: "holiday.heic", resourceFilename: "Adjustments.plist"), "holiday.aae")
        XCTAssertEqual(ArchivePlan.name(for: fullPhoto, primary: "my.trip.jpeg", resourceFilename: "FullSizeRender.jpg"), "my.trip_edited.jpg")
        XCTAssertEqual(ArchivePlan.name(for: paired, primary: "IMG_1", resourceFilename: ""), "IMG_1.mov")
        XCTAssertEqual(ArchivePlan.name(for: paired, primary: "IMG_1.HEIC", resourceFilename: "", uniformType: "com.apple.quicktime-movie"), "IMG_1.MOV")
    }

    func testEveryFileOfAnItemGetsItsOwnName() {
        // An edited JPEG: the original and the edited picture are both JPEGs.
        let types = [photo, paired, adjustment, fullPhoto, fullPaired]
        let sources = ["IMG_9.JPG", "IMG_9.MOV", "Adjustments.plist", "FullSizeRender.jpg", "FullSizeRender.mov"]
        let names = zip(types, sources).map { ArchivePlan.name(for: $0, primary: "IMG_9.JPG", resourceFilename: $1) }
        XCTAssertEqual(names, ["IMG_9.JPG", "IMG_9.MOV", "IMG_9.AAE", "IMG_9_edited.JPG", "IMG_9_edited.MOV"])
        XCTAssertEqual(Set(names.map { $0.lowercased() }).count, names.count)
    }

    // MARK: - Copied only when every file is

    func testAnItemCountsOnlyWhenEveryFileWasCopiedAndChecked() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? files.removeItem(at: root) }
        let first = root.appendingPathComponent("first", isDirectory: true), second = root.appendingPathComponent("second", isDirectory: true)
        try files.createDirectory(at: first, withIntermediateDirectories: true)
        try files.createDirectory(at: second, withIntermediateDirectories: true)
        let still = root.appendingPathComponent("IMG_7.HEIC"), motion = root.appendingPathComponent("IMG_7.MOV")
        try Data(repeating: 1, count: 40_000).write(to: still)
        try Data(repeating: 2, count: 90_000).write(to: motion)
        let gone = root.appendingPathComponent("IMG_7.AAE")
        func item(_ url: URL, _ type: Int) -> ArchiveItem {
            ArchiveItem(id: "one", name: url.lastPathComponent, source: .file(url), part: type)
        }

        // The third file can't be read: the item is not copied, whatever happened to the first two.
        let broken = [item(still, photo), item(motion, paired), item(gone, adjustment)]
        var tried = 0
        XCTAssertThrowsError(try ArchiveParts.every(broken) { file -> ArchiveReceipt in
            tried += 1
            return try VerifiedArchive.copy(file, to: first)
        })
        XCTAssertEqual(tried, 3, "It stops at the file that failed.")

        // Every file there: each has its own verified receipt, and the record lists the others as parts.
        let whole = [item(still, photo), item(motion, paired)]
        let receipts = try ArchiveParts.every(whole) { try VerifiedArchive.copy($0, to: second) }
        XCTAssertEqual(receipts.map(\.fingerprint.bytes), [40_000, 90_000])
        let parts = ArchiveParts.parts(whole, receipts.map { StoredPart(name: $0.url.lastPathComponent, fingerprint: $0.fingerprint) })
        XCTAssertEqual(parts, [ArchivedPart(type: paired, name: "IMG_7.MOV", bytes: 90_000, digest: receipts[1].fingerprint.digest)])

        XCTAssertThrowsError(try ArchiveParts.every([]) { try VerifiedArchive.copy($0, to: second) }, "Nothing copied is never a copy.")
    }

    func testProofNeedsAStampForEveryOtherFile() {
        XCTAssertTrue(ArchiveProver.partsProven(2, stamps: 2))
        XCTAssertFalse(ArchiveProver.partsProven(2, stamps: 1), "One file unchecked: the original stays.")
        XCTAssertFalse(ArchiveProver.partsProven(1, stamps: 2))
        XCTAssertFalse(ArchiveProver.partsProven(0, stamps: 0))
    }

    private func saved(_ name: String, bytes: Int64, parts: [ArchivedPart]? = nil, cloud: CloudService? = nil) -> ArchivedRecord {
        ArchivedRecord(id: name, name: name, folderName: "Archive", bytes: bytes, digest: "aa", date: Date(timeIntervalSince1970: 1_000),
                       viaHomeServer: false, folderBookmark: cloud == nil ? Data([9]) : nil, driveFileID: cloud == nil ? nil : "still-id",
                       photoID: "asset", cloud: cloud, cloudHash: cloud == nil ? nil : "still-hash", parts: parts)
    }

    func testEachFileOfACloudCopyIsCheckedAgainstItsOwnSizeAndFingerprint() throws {
        let live = saved("IMG_1.HEIC", bytes: 10, parts: [ArchivedPart(type: paired, name: "IMG_1.MOV", bytes: 20, digest: "bb", fileID: "video-id", cloudHash: "video-hash")],
                         cloud: .dropbox)
        let files = live.files
        XCTAssertEqual(files.map(\.name), ["IMG_1.HEIC", "IMG_1.MOV"])
        XCTAssertEqual(files.map(\.driveFileID), ["still-id", "video-id"])
        XCTAssertEqual(files.map(\.cloud), [.dropbox, .dropbox])
        XCTAssertNil(files[0].parts)
        XCTAssertNoThrow(try ArchiveProver.stamp(of: CloudStoredFile(bytes: 20, hash: "VIDEO-HASH"), for: files[1], in: .dropbox))
        XCTAssertThrowsError(try ArchiveProver.stamp(of: CloudStoredFile(bytes: 10, hash: "still-hash"), for: files[1], in: .dropbox),
                             "The still's size and fingerprint prove nothing about the video.")
        XCTAssertThrowsError(try ArchiveProver.stamp(of: CloudStoredFile(bytes: 20, hash: nil), for: files[1], in: .dropbox))
        XCTAssertEqual(ArchiveProver.fingerprint(of: files[1]), ArchiveFingerprint(bytes: 20, digest: "bb"))
    }

    func testAPartWithoutItsOwnFileIDNeverBorrowsTheStills() {
        let broken = saved("IMG_1.HEIC", bytes: 10, parts: [ArchivedPart(type: paired, name: "IMG_1.MOV", bytes: 20, digest: "bb")], cloud: .oneDrive)
        XCTAssertNil(broken.files[1].driveFileID)
        XCTAssertNil(broken.files[1].cloudHash)
    }

    func testTheTestRestoreAlwaysIncludesAnItemMadeOfSeveralFilesWhenThereIsOne() {
        let small = saved("small.HEIC", bytes: 5)
        let big = saved("big.MOV", bytes: 500)
        let live = saved("live.HEIC", bytes: 30, parts: [ArchivedPart(type: paired, name: "live.MOV", bytes: 40, digest: "bb")])
        let largerLive = saved("larger.HEIC", bytes: 60, parts: [ArchivedPart(type: paired, name: "larger.MOV", bytes: 80, digest: "cc")])
        XCTAssertEqual(RestoreTestChoice.records(from: [big, small]).map(\.name), ["small.HEIC"], "Unchanged for single files.")
        XCTAssertEqual(RestoreTestChoice.records(from: [big, largerLive, small, live]).map(\.name), ["small.HEIC", "live.HEIC"])
        XCTAssertEqual(RestoreTestChoice.records(from: [big, live]).map(\.name), ["live.HEIC"], "The smallest is the Live Photo, counted with its video.")
        XCTAssertTrue(RestoreTestChoice.records(from: []).isEmpty)
    }

    // MARK: - The ledger

    func testRecordsSavedBeforePartsStillReadAndBehaveAsSingleFiles() throws {
        // Exactly what earlier versions wrote: Files, Google Drive and Dropbox copies, none with parts.
        let old = [
            #"{"id":"a","name":"IMG_1.HEIC","folderName":"Drive","bytes":1234,"digest":"ab","date":700000000,"viaHomeServer":false,"folderBookmark":"AQID"}"#,
            #"{"id":"b","name":"IMG_2.MOV","folderName":"Google Drive","bytes":99,"digest":"cd","date":700000001,"viaHomeServer":false,"driveFileID":"f1","photoID":"p1"}"#,
            #"{"id":"c","name":"IMG_3.JPG","folderName":"Dropbox","bytes":7,"digest":"ef","date":700000002,"viaHomeServer":false,"driveFileID":"id:x","photoID":"p2","cloud":"dropbox","cloudHash":"hh"}"#,
        ]
        let records = try old.map { try JSONDecoder().decode(ArchivedRecord.self, from: Data($0.utf8)) }
        for record in records {
            XCTAssertNil(record.parts)
            XCTAssertFalse(record.hasParts)
            XCTAssertEqual(record.files, [record], "One file, itself: every check runs exactly as before.")
            XCTAssertEqual(record.totalBytes, record.bytes)
            XCTAssertTrue(record.partTypes.isEmpty)
            XCTAssertNil(record.filesNote)
        }
        XCTAssertEqual(records[0].folderBookmark, Data([1, 2, 3]))
        XCTAssertEqual(records[2].cloud, .dropbox)
        XCTAssertEqual(RestoreTestChoice.records(from: records).map(\.id), ["c"])
    }

    func testASingleFileCopyIsStillWrittenWithoutParts() throws {
        let json = String(decoding: try JSONEncoder().encode(saved("IMG_1.HEIC", bytes: 10)), as: UTF8.self)
        XCTAssertFalse(json.contains("parts"), "New single-file records look just like the old ones.")
    }

    func testOldAndNewRecordsLiveTogetherAndTheTotalCountsEveryFile() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".sqlite")
        defer { try? FileManager.default.removeItem(at: path) }
        let store = try InventoryStore(url: path)
        XCTAssertEqual(try store.archivedBytes(), 0)
        let single = saved("plain.HEIC", bytes: 1_000)
        let live = saved("live.HEIC", bytes: 300, parts: [ArchivedPart(type: paired, name: "live.MOV", bytes: 700, digest: "bb")])
        let edited = saved("edited.HEIC", bytes: 50, parts: [ArchivedPart(type: adjustment, name: "edited.AAE", bytes: 2, digest: "cc"),
                                                              ArchivedPart(type: fullPhoto, name: "edited_edited.JPG", bytes: 48, digest: "dd", fileID: "x", cloudHash: "y")])
        try store.saveArchived([single])
        XCTAssertEqual(try store.archivedBytes(), 1_000, "Unchanged when nothing has parts.")
        try store.saveArchived([live, edited])
        let back = try InventoryStore(url: path).archived()
        XCTAssertEqual(back.sorted { $0.id < $1.id }, [edited, live, single])
        XCTAssertEqual(try store.archivedBytes(), 1_000 + 1_000 + 100)
        XCTAssertEqual(try store.archivedCount(), 3, "One item each, however many files.")
        let read = try XCTUnwrap(back.first { $0.id == "edited.HEIC" })
        XCTAssertEqual(read.partTypes, [photo, adjustment, fullPhoto])
        XCTAssertEqual(read.totalBytes, 100)
        XCTAssertEqual(read.filesNote, "3 files")
        XCTAssertEqual(ArchiveDay.group(back).first?.bytes, 2_100)
    }

    func testDeleteSizeCountsEveryFileOfAnItem() {
        let live = saved("live.HEIC", bytes: 300, parts: [ArchivedPart(type: paired, name: "live.MOV", bytes: 700, digest: "bb")])
        let item = ArchiveItem(id: "asset", name: "live.HEIC", source: .photo("asset", expected: nil))
        let done = ArchiveCompletion(items: [item], bytes: 1_000, place: "Drive", driveFolderID: nil, copies: ["asset": live])
        XCTAssertEqual(done.bytes(of: [item]), 1_000)
    }

    // MARK: - Reading the right file

    func testASecondFileOfAnItemShowsItsOwnDownloadAndOnlyTheStillHasASecondWay() {
        XCTAssertEqual(ArchiveParts.liveKey("asset", part: nil), "asset")
        XCTAssertEqual(ArchiveParts.liveKey("asset", part: photo), "asset")
        XCTAssertNotEqual(ArchiveParts.liveKey("asset", part: paired), "asset")
        XCTAssertTrue(ArchiveParts.allowsImageFallback(part: nil))
        XCTAssertTrue(ArchiveParts.allowsImageFallback(part: photo))
        XCTAssertFalse(ArchiveParts.allowsImageFallback(part: paired))
        XCTAssertFalse(ArchiveParts.allowsImageFallback(part: fullPhoto), "Photos' second way returns the unedited original only.")
    }

    @MainActor
    func testWordingNoLongerSaysLivePhotosAndEditsCannotBeCopied() {
        let unsupported = ArchiveError.unsupportedPhoto.localizedDescription
        XCTAssertFalse(unsupported.contains("Live Photos, slo-mo"))
        XCTAssertTrue(unsupported.contains("Slo-mo, edited videos and RAW pairs aren't supported yet."))
        XCTAssertEqual(ArchiveRun.reason(for: ArchiveError.unsupportedPhoto), "Kind not supported yet (slo-mo, edited videos, RAW)")
    }
}
