import Photos
import XCTest
@testable import SmartPhotoVault

/// The checks that keep a Live Photo or edited photo on the iPhone when its copy isn't the whole,
/// current item: an edit made after (or during) the copy, an upload that stops partway, a restore that
/// comes back incomplete, and a folder restore that can't finish.
final class ArchivePartsSafetyTests: XCTestCase {
    private let photo = PHAssetResourceType.photo.rawValue
    private let paired = PHAssetResourceType.pairedVideo.rawValue
    private let adjustment = PHAssetResourceType.adjustmentData.rawValue
    private let fullPhoto = PHAssetResourceType.fullSizePhoto.rawValue
    private let fullPaired = PHAssetResourceType.fullSizePairedVideo.rawValue

    private func fp(_ digest: String, _ bytes: Int64) -> ArchiveFingerprint { ArchiveFingerprint(bytes: bytes, digest: digest) }

    /// An edited Live Photo as recorded: still, video, instructions, edited picture, edited video.
    private var edited: ArchivedRecord {
        ArchivedRecord(id: "r", name: "IMG_1.HEIC", folderName: "Drive", bytes: 100, digest: "still", date: Date(timeIntervalSince1970: 1_000),
                       viaHomeServer: false, folderBookmark: Data([1]), photoID: "asset",
                       parts: [ArchivedPart(type: paired, name: "IMG_1.MOV", bytes: 200, digest: "video"),
                               ArchivedPart(type: adjustment, name: "IMG_1.AAE", bytes: 3, digest: "EDIT-A"),
                               ArchivedPart(type: fullPhoto, name: "IMG_1_edited.JPG", bytes: 90, digest: "render-a"),
                               ArchivedPart(type: fullPaired, name: "IMG_1_edited.MOV", bytes: 180, digest: "motion-a")])
    }

    // MARK: - An edit made after the copy

    func testTheSameEditStillInPhotosPasses() throws {
        let now = [adjustment: fp("edit-a", 3), fullPhoto: fp("render-a", 90), fullPaired: fp("motion-a", 180)]
        var read: [Int] = []
        XCTAssertNoThrow(try ArchiveProver.sameEdit(as: edited) { type in
            read.append(type)
            return try XCTUnwrap(now[type])
        })
        XCTAssertEqual(read, [adjustment, fullPhoto, fullPaired], "Only the files an edit rewrites are read again.")
    }

    func testASecondEditWithTheSameKindsOfFilesIsRejected() {
        // Edit B replaced edit A: the same kinds of files, even the same sizes, different bytes.
        let unchanged = [adjustment: fp("edit-a", 3), fullPhoto: fp("render-a", 90), fullPaired: fp("motion-a", 180)]
        let changes: [(String, Int, ArchiveFingerprint)] = [
            ("new instructions, same size", adjustment, fp("edit-b", 3)),
            ("new edited picture, same size", fullPhoto, fp("render-b", 90)),
            ("new edited video", fullPaired, fp("motion-b", 181)),
            ("same bytes claimed, different size", fullPhoto, fp("render-a", 91)),
        ]
        for (why, type, fingerprint) in changes {
            var now = unchanged
            now[type] = fingerprint
            XCTAssertThrowsError(try ArchiveProver.sameEdit(as: edited) { try XCTUnwrap(now[$0]) }, why) {
                XCTAssertEqual($0 as? ArchiveProofError, .editChanged, why)
            }
        }
    }

    func testAnEditFileThatCannotBeReadNeverPasses() {
        XCTAssertThrowsError(try ArchiveProver.sameEdit(as: edited) { _ in throw ArchiveError.iCloudDownload }) {
            XCTAssertEqual($0 as? ArchiveError, .iCloudDownload, "Unreadable is not unchanged: the original stays.")
        }
    }

    func testALivePhotoWithoutAnEditHasNothingToReadAgain() {
        let live = ArchivedRecord(id: "r", name: "IMG_2.HEIC", folderName: "Drive", bytes: 100, digest: "still", date: Date(),
                                  viaHomeServer: false, folderBookmark: Data([1]),
                                  parts: [ArchivedPart(type: paired, name: "IMG_2.MOV", bytes: 200, digest: "video")])
        XCTAssertNoThrow(try ArchiveProver.sameEdit(as: live) { _ in
            XCTFail("The original still and video are never rewritten by Photos.")
            throw ArchiveError.verification
        })
    }

    func testTheStaysReasonSaysWhatHappened() {
        XCTAssertEqual(ArchiveProofError.editChanged.localizedDescription,
                       "It was edited after it was copied, so its copy doesn't hold the latest edit. Copy it again.")
    }

    // MARK: - An edit made while copying

    private func part(_ name: String, _ type: Int) -> ArchiveItem {
        ArchiveItem(id: "one", name: name, source: .photo("asset", expected: nil), part: type)
    }

    func testAnEditMadeWhileCopyingRefusesTheCopy() {
        let files = [part("IMG_1.HEIC", photo), part("IMG_1.AAE", adjustment), part("IMG_1_edited.JPG", fullPhoto)]
        let copied = [fp("still", 100), fp("edit-a", 3), fp("render-a", 90)]
        var read: [String] = []
        XCTAssertNoThrow(try ArchiveParts.requireSameEdit(files, copied) { file in
            read.append(file.name)
            return copied[files.firstIndex { $0.name == file.name }!]
        })
        XCTAssertEqual(read, ["IMG_1.AAE", "IMG_1_edited.JPG"])

        // The instructions were copied from edit A; by the time the picture was copied, Photos held edit B.
        XCTAssertThrowsError(try ArchiveParts.requireSameEdit(files, copied) { file in
            file.part == self.adjustment ? self.fp("edit-b", 3) : copied[files.firstIndex { $0.name == file.name }!]
        }) { XCTAssertEqual($0 as? ArchiveError, .editedDuringCopy) }
        XCTAssertThrowsError(try ArchiveParts.requireSameEdit(files, Array(copied.dropLast())) { _ in self.fp("x", 1) }) {
            XCTAssertEqual($0 as? ArchiveError, .verification, "A file with no fingerprint to compare is never accepted.")
        }
    }

    @MainActor
    func testTheCopyErrorSaysWhatHappened() {
        XCTAssertEqual(ArchiveError.editedDuringCopy.localizedDescription,
                       "It was edited while it was being copied, so the copy wasn't counted. Copy it again.")
        XCTAssertEqual(ArchiveRun.reason(for: ArchiveError.editedDuringCopy), "Edited while it was being copied")
    }

    // MARK: - A cloud upload that stops partway

    private func uploaded(_ file: ArchiveItem) -> CloudUpload {
        CloudUpload(fileID: "id-\(file.name)", name: file.name, fingerprint: fp("d-\(file.name)", 10), serviceHash: "h-\(file.name)")
    }

    func testACloudUploadThatStopsPartwayRecordsNothing() async {
        let files = [part("IMG_1.HEIC", photo), part("IMG_1.MOV", paired), part("IMG_1.AAE", adjustment)]
        var sent: [String] = []
        var checked = false
        do {
            _ = try await CloudArchive.uploadParts(files, send: { file in
                sent.append(file.name)
                if file.part == self.paired { throw CloudError.server("Dropbox", 500) }
                return self.uploaded(file)
            }, sameEdit: { _, _ in checked = true })
            XCTFail("An item with a file that didn't upload must not come back as stored.")
        } catch {
            XCTAssertEqual(error as? CloudError, .server("Dropbox", 500))
        }
        XCTAssertEqual(sent, ["IMG_1.HEIC", "IMG_1.MOV"], "It stops at the file that failed.")
        XCTAssertFalse(checked)
    }

    func testACloudUploadOfAnItemEditedMeanwhileRecordsNothing() async {
        let files = [part("IMG_1.HEIC", photo), part("IMG_1.AAE", adjustment), part("IMG_1_edited.JPG", fullPhoto)]
        do {
            _ = try await CloudArchive.uploadParts(files, send: { self.uploaded($0) },
                                                   sameEdit: { _, _ in throw ArchiveError.editedDuringCopy })
            XCTFail("Every file uploaded, but they are no longer one edit.")
        } catch {
            XCTAssertEqual(error as? ArchiveError, .editedDuringCopy)
        }
    }

    func testACloudUploadOfEveryFileListsTheOthersAsParts() async throws {
        let files = [part("IMG_1.HEIC", photo), part("IMG_1.MOV", paired)]
        var compared: [ArchiveFingerprint] = []
        let stored = try await CloudArchive.uploadParts(files, send: { self.uploaded($0) }, sameEdit: { _, copied in compared = copied })
        XCTAssertEqual(stored.upload.fileID, "id-IMG_1.HEIC")
        XCTAssertEqual(stored.parts, [ArchivedPart(type: paired, name: "IMG_1.MOV", bytes: 10, digest: "d-IMG_1.MOV",
                                                   fileID: "id-IMG_1.MOV", cloudHash: "h-IMG_1.MOV")])
        XCTAssertEqual(compared.count, 2, "The edit check sees what was actually uploaded.")
    }

    // MARK: - Photos keeps only part of a restored item

    func testAnItemThatCameBackWithoutEveryPartIsReported() {
        XCTAssertNoThrow(try ArchiveRestore.requireEveryPart([photo, paired], of: [photo, paired], name: "IMG_1.HEIC"))
        XCTAssertNoThrow(try ArchiveRestore.requireEveryPart([paired, photo, 19], of: [photo, paired], name: "IMG_1.HEIC"))
        let incomplete: [([Int], [Int])] = [([photo], [photo, paired]), ([photo, fullPhoto], [photo, adjustment, fullPhoto]), ([], [photo, paired]),
                                            ([photo], [])]
        for (found, wanted) in incomplete {
            XCTAssertThrowsError(try ArchiveRestore.requireEveryPart(found, of: wanted, name: "IMG_1.HEIC")) { error in
                guard case ArchiveRestoreError.partsMissing = error else { return XCTFail("\(error)") }
                XCTAssertTrue(error.localizedDescription.contains("didn't keep its Live Photo or edit part"))
            }
        }
    }

    // MARK: - Putting back to a folder

    /// A Live Photo archived to a folder: both files there, and its record.
    private func archivedLivePhoto(in root: URL) throws -> (record: ArchivedRecord, archive: URL, still: Data, motion: Data) {
        let files = FileManager.default
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        try files.createDirectory(at: archive, withIntermediateDirectories: true)
        let still = Data(repeating: 3, count: 30_000), motion = Data(repeating: 4, count: 70_000)
        try still.write(to: archive.appendingPathComponent("IMG_5.HEIC"))
        try motion.write(to: archive.appendingPathComponent("IMG_5.MOV"))
        let record = ArchivedRecord(id: "live", name: "IMG_5.HEIC", folderName: "archive", bytes: Int64(still.count),
                                    digest: try GoogleDriveClient.sha256(of: archive.appendingPathComponent("IMG_5.HEIC")), date: Date(),
                                    viaHomeServer: false, folderBookmark: try archive.bookmarkData(),
                                    parts: [ArchivedPart(type: paired, name: "IMG_5.MOV", bytes: Int64(motion.count),
                                                         digest: try GoogleDriveClient.sha256(of: archive.appendingPathComponent("IMG_5.MOV")))])
        return (record, archive, still, motion)
    }

    private func folders() throws -> (root: URL, target: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TidyAwayRestoreTest-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return (root, target)
    }

    func testPuttingBackToAFolderWritesEveryFile() async throws {
        let (root, target) = try folders()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = try archivedLivePhoto(in: root)
        try await ArchiveRestore.toFolder(live.record, folder: target, wifi: ArchiveWiFi())
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("IMG_5.HEIC")), live.still)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("IMG_5.MOV")), live.motion)
        XCTAssertEqual(try Data(contentsOf: live.archive.appendingPathComponent("IMG_5.MOV")), live.motion, "The archive copy stays.")
    }

    func testANameAlreadyTakenStopsTheWholeItemAndTouchesNothing() async throws {
        let (root, target) = try folders()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = try archivedLivePhoto(in: root)
        // The second file's name is taken by something of the person's own.
        let mine = Data("my own video".utf8)
        try mine.write(to: target.appendingPathComponent("IMG_5.MOV"))
        do {
            try await ArchiveRestore.toFolder(live.record, folder: target, wifi: ArchiveWiFi())
            XCTFail("Nothing may be overwritten.")
        } catch {
            XCTAssertEqual(error as? ArchiveError, .conflict)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), ["IMG_5.MOV"], "The still was not left behind on its own.")
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("IMG_5.MOV")), mine)
    }

    func testALaterFileThatFailsTakesBackOnlyWhatThisAttemptWrote() async throws {
        let (root, target) = try folders()
        defer { try? FileManager.default.removeItem(at: root) }
        let live = try archivedLivePhoto(in: root)
        let kept = Data("already here".utf8)
        try kept.write(to: target.appendingPathComponent("notes.txt"))
        // The video in the archive no longer matches its fingerprint: the still is written, then the video fails.
        try Data(repeating: 9, count: live.motion.count).write(to: live.archive.appendingPathComponent("IMG_5.MOV"))
        do {
            try await ArchiveRestore.toFolder(live.record, folder: target, wifi: ArchiveWiFi())
            XCTFail("A changed part must fail the item.")
        } catch { }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), ["notes.txt"],
                       "The still this attempt wrote is taken back; what was already there is not touched.")
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("notes.txt")), kept)

        // With the archive whole again, the same folder takes the item: no leftover blocks the retry.
        try live.motion.write(to: live.archive.appendingPathComponent("IMG_5.MOV"))
        try await ArchiveRestore.toFolder(live.record, folder: target, wifi: ArchiveWiFi())
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: target.path)), ["notes.txt", "IMG_5.HEIC", "IMG_5.MOV"])
    }
}
